//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationOCI
import Foundation
import NymphKit

// LinuxImageBaker 觸碰 Containerization 的真容器 API——整檔 arch gate，比照 LinuxGuestEngine.swift。

#if arch(arm64)

/// 從 base 映像燒一顆新的 Linux 映像，登記進別名表。
///
/// 流程：
/// 1. 照 base 起一台容器（接網路，設定腳本通常要裝套件）。
/// 2. 設定腳本經 stdin 寫進容器的 `/tmp`，以登入 shell 執行；輸出即時轉給呼叫端。
/// 3. 確認容器裡是 GNU tar，把整個 rootfs 匯成 tar、串流寫到本機（不經記憶體）。
/// 4. 停掉、刪掉這台容器。
/// 5. tar 封成單層映像（``SingleLayerImageLayout``）、載入 image store。
/// 6. 以新映像起一台容器跑冒煙（與呼叫端的驗證腳本）；不過就把映像從 store 移除、不登記。
/// 7. 寫進別名表（``LinuxImageManifest/upsert(alias:entry:in:replacing:)``）。
///
/// 不設逾時：要中途停下時呼叫 ``stop()``，它整台停掉當下那台容器，進行中的命令隨之結束。
/// `LinuxProcess.wait(timeoutInSeconds:)` 逾時只擲錯、不收行程，靠它收不乾淨。
///
/// - Important: image store 的參照表沒有跨行程的鎖，燒製期間 daemon 若也在拉映像，兩邊可能互相
///   蓋掉；兩個行程各建一顆容器網路能否並存也未驗過——燒製時讓 daemon 停著。
public final class LinuxImageBaker: @unchecked Sendable {

	// MARK: Public

	/// - Parameters:
	///   - resolver: 解析 base 別名。
	///   - kernelProvisioner: kernel fetch-on-demand。
	///   - stateRoot: 容器 image store／rootfs 根目錄（與 daemon 同一份，新映像才看得到）。
	///   - networkProvider: 容器網路的來源。
	///   - manifestURL: 要寫入的別名表。
	public init(
		resolver: LinuxImageResolver,
		kernelProvisioner: LinuxKernelProvisioner = .init(),
		stateRoot: URL = LinuxNodePaths.containerRoot(),
		networkProvider: LinuxNetworkProvider,
		manifestURL: URL
	) {
		self.resolver = resolver
		self.kernelProvisioner = kernelProvisioner
		self.stateRoot = stateRoot
		self.networkProvider = networkProvider
		self.manifestURL = manifestURL
	}

	/// 燒一顆映像（流程見型別說明）。
	///
	/// - Parameters:
	///   - plan: 別名、參照與 rootfs 大小。
	///   - provisionScript: 設定腳本的內容。
	///   - verifyScript: 冒煙之後在新映像裡多跑的驗證腳本；`nil`＝不跑。
	///   - options: 容器規格與輸出去處。
	/// - Returns: 新映像的參照與 digest。
	/// - Throws: ``LinuxImageBakeError``、``NymphError``、別名表的寫入錯誤，或 Containerization 的錯誤。
	public func bake(
		plan: LinuxImageBakePlan,
		provisionScript: Data,
		verifyScript: Data?,
		options: LinuxImageBakeOptions
	) async throws -> LinuxImageBakeResult {
		let base: LinuxGuestSpec = try resolver.resolve(plan.base)
		let run: Run = .init(
			engine: LinuxGuestEngine(
				resolver: resolver,
				kernelProvisioner: kernelProvisioner,
				stateRoot: stateRoot,
				networkProvider: networkProvider
			),
			options: options
		)
		let staging: URL = stateRoot.appending(component: "bake").appending(component: UUID().uuidString.lowercased())
		try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		// 暫存目錄可重建、刪不掉也不影響結果，不讓清理失敗蓋掉燒製本身的結果。
		defer { try? FileManager.default.removeItem(at: staging) }

		let exported: Exported = try await provisionAndExport(
			base: base,
			plan: plan,
			provisionScript: provisionScript,
			staging: staging,
			run: run
		)
		let layout: SingleLayerImageLayout.Output = try await load(
			exported,
			base: base,
			plan: plan,
			staging: staging,
			run: run
		)
		do {
			try await smoke(plan: plan, kernel: base.kernel, verifyScript: verifyScript, run: run)
		} catch {
			// 起不來或驗不過的映像不留在 store 裡：留著的話，下一次用同一個參照會直接拿到它。只移除
			// 參照、不清孤兒 blob——清理會掃整個 store，daemon 若同時在用會受影響。
			try? await exported.store.delete(reference: plan.reference)
			throw error
		}

		do {
			// 冒煙收尾時才收到的停止請求也不登記：呼叫端要的是「停下、什麼都不留」。
			guard !withLock({ stopRequested }) else { throw LinuxImageBakeError.stopped }
			try LinuxImageManifest.upsert(
				alias: plan.alias,
				entry: plan.manifestEntry,
				in: manifestURL,
				replacing: plan.replacing
			)
		} catch {
			// 沒登記上的映像沒有別名可達，同樣移除。
			try? await exported.store.delete(reference: plan.reference)
			throw error
		}
		return LinuxImageBakeResult(
			reference: layout.reference,
			manifestDigest: layout.manifestDigest,
			layerSize: layout.layerSize,
			manifestURL: manifestURL
		)
	}

	/// 停掉當下那台容器，並讓之後的步驟不再起新容器。
	///
	/// 給收到 SIGINT／SIGTERM 的呼叫端用：進行中的命令會因容器停機而結束，
	/// ``bake(plan:provisionScript:verifyScript:options:)`` 隨之擲錯、收掉容器與暫存檔。
	public func stop() async {
		let stopping: Task<Void, Never>? = withLock {
			stopRequested = true
			// 第二次訊號沿用第一次的停機：再發一次只會碰到已標成停止的容器、立刻結束，收容器那一端
			// 若等到的是這一個，就會在第一次停機還沒做完時刪掉容器。
			if let pendingStop {
				return pendingStop
			}
			guard let control: LinuxGuestControl = active else { return nil }
			// 停機失敗時容器多半已停；呼叫端只要「停下」，沒有可處理的錯誤。
			let task: Task<Void, Never> = Task { try? await control.forceStop() }
			pendingStop = task
			return task
		}
		await stopping?.value
	}

	// MARK: Private

	/// 一次燒製共用的引擎與選項。
	private struct Run {

		/// 建容器用的引擎。
		internal let engine: LinuxGuestEngine

		/// 容器規格與輸出去處。
		internal let options: LinuxImageBakeOptions
	}

	/// 設定容器的產物：匯出的 tar、容器所用的 image store、base 映像。
	private struct Exported: Sendable {

		/// 匯出的 rootfs tar。
		internal let layer: URL

		/// 設定容器所用的 image store，新映像載回這裡。
		internal let store: ImageStore

		/// base 映像（取 config 與 digest）。
		internal let baseImage: Containerization.Image
	}

	/// 護住 ``active``、``stopRequested``、``pendingStop``：``stop()`` 由訊號處理的 Task 呼叫。
	private let lock: NSLock = .init()

	/// 解析 base 別名。
	private let resolver: LinuxImageResolver

	/// kernel fetch-on-demand。
	private let kernelProvisioner: LinuxKernelProvisioner

	/// 容器 image store／rootfs 根目錄。
	private let stateRoot: URL

	/// 容器網路的來源。
	private let networkProvider: LinuxNetworkProvider

	/// 要寫入的別名表。
	private let manifestURL: URL

	/// 當下起著的容器；``stop()`` 停的就是它。
	private var active: LinuxGuestControl?

	/// 是否已要求停止；只會從 `false` 變 `true`。
	private var stopRequested: Bool = false

	/// ``stop()`` 發出、可能還沒做完的停機；收容器前要先等它，免得刪掉一台還在收尾的容器。
	private var pendingStop: Task<Void, Never>?

	/// 持鎖執行 `body`。
	/// - Parameter body: 要做的事。
	/// - Returns: `body` 的回傳值。
	/// - Throws: `body` 擲出的錯誤。
	private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	/// 照 base 起容器、跑設定腳本、匯出 rootfs；容器在回傳前收掉。
	/// - Parameters:
	///   - base: base 解析結果。
	///   - plan: rootfs 大小。
	///   - provisionScript: 設定腳本的內容。
	///   - staging: 暫存目錄。
	///   - run: 引擎與選項。
	/// - Returns: 匯出的 tar 與 base 映像。
	/// - Throws: ``LinuxImageBakeError``，或執行命令時的錯誤。
	private func provisionAndExport(
		base: LinuxGuestSpec,
		plan: LinuxImageBakePlan,
		provisionScript: Data,
		staging: URL,
		run: Run
	) async throws -> Exported {
		let spec: LinuxGuestSpec = .init(
			imageReference: base.imageReference,
			kernel: base.kernel,
			rootfsSizeInBytes: plan.rootfsSizeInBytes ?? base.rootfsSizeInBytes
		)
		run.options.progress("starting base \(base.imageReference)")
		return try await withGuest(spec: spec, stage: "provision", run: run) { control in
			let store: ImageStore = control.imageStore
			let baseImage: Containerization.Image = try await store.get(reference: base.imageReference)
			try await stage(provisionScript, at: LinuxImageBakePlan.stagedProvisionPath, in: control)
			run.options.progress("running provision script")
			let exitCode: Int32 = try await runScript(at: LinuxImageBakePlan.stagedProvisionPath, in: control, run: run)
			guard exitCode == 0 else { throw LinuxImageBakeError.provisionFailed(exitCode: exitCode) }
			let layer: URL = try await export(from: control, into: staging, run: run)
			return Exported(layer: layer, store: store, baseImage: baseImage)
		}
	}

	/// 把匯出的 tar 封成 layout、載入 image store；layout 目錄載入後即刪。
	/// - Parameters:
	///   - exported: 設定容器的產物。
	///   - base: base 解析結果。
	///   - plan: 新映像的參照。
	///   - staging: 暫存目錄。
	///   - run: 引擎與選項。
	/// - Returns: 寫出的 layout。
	/// - Throws: 封裝或載入時的錯誤。
	private func load(
		_ exported: Exported,
		base: LinuxGuestSpec,
		plan: LinuxImageBakePlan,
		staging: URL,
		run: Run
	) async throws -> SingleLayerImageLayout.Output {
		let directory: URL = staging.appending(component: "layout")
		let baseConfig: ContainerizationOCI.Image = try await exported.baseImage.config(for: .current)
		let layout: SingleLayerImageLayout.Output = try SingleLayerImageLayout.write(
			layer: exported.layer,
			baseConfig: baseConfig,
			reference: plan.reference,
			createdBy: "mayfly linux bake \(plan.alias) --base \(plan.base)",
			baseReference: base.imageReference,
			baseDigest: exported.baseImage.digest,
			created: Date(),
			into: directory
		)
		run.options.progress("loading \(layout.reference) (\(layout.layerSize) bytes)")
		_ = try await exported.store.load(from: directory)
		// 載入時已複製進 content store；layout 刪不掉時由外層暫存目錄一併清。
		try? FileManager.default.removeItem(at: directory)
		return layout
	}

	/// 起一台容器、等它 ready、跑 `body`，無論成敗都停機並刪掉容器。
	/// - Parameters:
	///   - spec: 映像參照、kernel 與 rootfs 大小。
	///   - stage: 階段名，只用於訊息。
	///   - run: 引擎與選項。
	///   - body: 容器 ready 之後要做的事。
	/// - Returns: `body` 的回傳值。
	/// - Throws: ``LinuxImageBakeError``，或 `body` 擲出的錯誤。
	private func withGuest<Result: Sendable>(
		spec: LinuxGuestSpec,
		stage: String,
		run: Run,
		body: (LinuxGuestControl) async throws -> Result
	) async throws -> Result {
		guard !withLock({ stopRequested }) else { throw LinuxImageBakeError.stopped }
		let control: LinuxGuestControl = try await run.engine.makeGuest(
			spec: spec,
			cpus: run.options.cpus,
			memoryGiB: run.options.memoryGiB,
			readinessTimeout: run.options.readinessTimeout
		).control
		withLock { active = control }
		let result: Result
		do {
			// 註冊與停止請求之間有空檔：stop() 若落在 makeGuest 期間，它停不到這一台，這裡補判一次。
			guard !withLock({ stopRequested }) else { throw LinuxImageBakeError.stopped }
			try await control.start()
			// stop() 若落在上一行判斷與 start() 之間，它的 forceStop 碰到的是還沒開機的容器、什麼都沒做；
			// 開機後再判一次，不讓這一台把整段設定跑完。
			guard !withLock({ stopRequested }) else { throw LinuxImageBakeError.stopped }
			_ = try await control.waitUntilReady()
			guard await control.currentState() == .ready else { throw LinuxImageBakeError.guestNotReady(stage: stage) }
			result = try await body(control)
		} catch {
			await release(control)
			throw withLock({ stopRequested }) ? LinuxImageBakeError.stopped : error
		}
		await release(control)
		return result
	}

	/// 停機、刪容器、取消登記。
	/// - Parameter control: 要收的容器。
	private func release(_ control: LinuxGuestControl) async {
		await withLock({ pendingStop })?.value
		// 收尾路徑：容器可能已停、已刪，失敗沒有可處理的對象，原本的錯誤或結果才是要回報的。
		try? await control.forceStop()
		try? control.destroyClone()
		withLock { active = nil }
	}

	/// 把一段腳本寫進容器、設成可執行。
	/// - Parameters:
	///   - script: 腳本內容。
	///   - path: 容器內的落點。
	///   - control: 容器。
	/// - Throws: ``LinuxImageBakeError/stagingFailed(exitCode:)``，或執行命令時的錯誤。
	private func stage(_ script: Data, at path: String, in control: LinuxGuestControl) async throws {
		let discarded: BufferedOutputWriter = .init()
		let exitCode: Int32 = try await control.stream(
			LinuxImageBakePlan.stageArguments(path: path),
			standardInput: script,
			standardOutput: discarded,
			standardError: discarded
		)
		guard exitCode == 0 else { throw LinuxImageBakeError.stagingFailed(exitCode: exitCode) }
	}

	/// 以登入 shell 跑一支已落地的腳本，輸出轉給呼叫端。
	/// - Parameters:
	///   - path: 腳本在容器內的落點。
	///   - control: 容器。
	///   - run: 輸出去處。
	/// - Returns: 結束碼。
	/// - Throws: 執行命令時的錯誤。
	private func runScript(at path: String, in control: LinuxGuestControl, run: Run) async throws -> Int32 {
		try await control.stream(
			LinuxImageBakePlan.runScriptArguments(path: path),
			standardInput: nil,
			standardOutput: OutputForwardingWriter(forward: run.options.output),
			standardError: OutputForwardingWriter(forward: run.options.output)
		)
	}

	/// 把 rootfs 匯出成暫存目錄下的 tar 檔。
	/// - Parameters:
	///   - control: 已跑完設定的容器。
	///   - directory: 暫存目錄（與 image store 同一個卷）。
	///   - run: 進度與 tar 的 stderr 的去處。
	/// - Returns: tar 檔路徑。
	/// - Throws: ``LinuxImageBakeError``，或執行命令、建檔時的錯誤。
	private func export(from control: LinuxGuestControl, into directory: URL, run: Run) async throws -> URL {
		let layer: URL = directory.appending(component: "rootfs.tar")
		run.options.progress("exporting root filesystem")
		try await control.exportRootFilesystem(to: layer, standardError: OutputForwardingWriter(forward: run.options.output))
		return layer
	}

	/// 以新映像起一台容器，跑冒煙與驗證腳本。
	/// - Parameters:
	///   - plan: 新映像的參照與 rootfs 大小。
	///   - kernel: 開機用的 kernel。
	///   - verifyScript: 呼叫端的驗證腳本；`nil`＝不跑。
	///   - run: 引擎與選項。
	/// - Throws: ``LinuxImageBakeError``，或執行命令時的錯誤。
	private func smoke(plan: LinuxImageBakePlan, kernel: LinuxKernelArchive, verifyScript: Data?, run: Run) async throws {
		let spec: LinuxGuestSpec = .init(
			imageReference: plan.reference,
			kernel: kernel,
			rootfsSizeInBytes: plan.rootfsSizeInBytes
		)
		run.options.progress("smoke-testing \(plan.reference)")
		try await withGuest(spec: spec, stage: "smoke", run: run) { control in
			let smokeExit: Int32 = try await control.stream(
				LinuxImageBakePlan.smokeArguments,
				standardInput: nil,
				standardOutput: OutputForwardingWriter(forward: run.options.output),
				standardError: OutputForwardingWriter(forward: run.options.output)
			)
			guard smokeExit == 0 else { throw LinuxImageBakeError.smokeFailed(exitCode: smokeExit) }
			guard let verifyScript else { return }
			try await stage(verifyScript, at: LinuxImageBakePlan.stagedVerifyPath, in: control)
			run.options.progress("running verify script")
			let verifyExit: Int32 = try await runScript(at: LinuxImageBakePlan.stagedVerifyPath, in: control, run: run)
			guard verifyExit == 0 else { throw LinuxImageBakeError.verifyFailed(exitCode: verifyExit) }
		}
	}
}

#endif
