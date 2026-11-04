//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Dispatch
import Foundation
import LinuxNodeKit

/// `mayfly linux bake <alias> --base <base> --provision <script>`：燒一顆 Linux 映像、登記成別名。
///
/// 編排在 `LinuxImageBaker`，這層只做 argv、讀腳本檔、接訊號與輸出。成功時 stdout 印一行新映像的
/// 參照；進度走紀錄、容器內命令的輸出原樣轉到 stderr。SIGINT／SIGTERM 整台停掉當下的容器、收掉
/// 暫存，不登記別名。
internal struct LinuxBakeCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "bake",
		abstract: "Bake a Linux image from a base image and a provision script, and register it as an alias.",
		discussion: """
		Starts a container from the base image, runs the provision script in it as root with \
		`bash -l`, exports the root filesystem, loads it as a single-layer image, smoke-tests \
		a container started from that image, and writes the alias to linux-images.json under \
		the golden root. Stop the nymph daemon while baking and start it again afterwards \
		to pick up the alias.
		"""
	)

	/// 新別名。
	@Argument(help: "Alias to register in linux-images.json.")
	internal var alias: String

	/// base：別名或完整的映像參照。
	@Option(help: "Base image: an alias or a full image reference.")
	internal var base: String

	/// 設定腳本的路徑。
	@Option(help: "Path to the provision script, run inside the container with `bash -l`.")
	internal var provision: String

	/// 冒煙之後在新映像裡多跑的驗證腳本。
	@Option(help: "Path to an extra verification script, run in a container started from the new image.")
	internal var verify: String?

	/// rootfs 大小（GiB）；未給時沿用 base 別名的大小。
	@Option(name: .customLong("rootfs-gib"), help: "Root filesystem size in GiB (default: the base alias's size).")
	internal var rootfsGiB: Int?

	/// 容器的 vCPU 數。
	@Option(help: "Virtual CPU count for the containers.")
	internal var cpus: Int = 4

	/// 容器的記憶體（GiB）。
	@Option(name: .customLong("memory-gib"), help: "Memory in GiB for the containers.")
	internal var memoryGiB: Int = 4

	/// 每台容器的 readiness 等待上限（秒）。
	@Option(name: .customLong("readiness-timeout"), help: "Readiness wait ceiling in seconds for each container.")
	internal var readinessTimeoutSeconds: Int = 180

	/// 別名已存在時覆寫。
	@Flag(help: "Overwrite the alias if it already exists.")
	internal var replace: Bool = false

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 數值選項的範圍。
	internal func validate() throws {
		guard cpus > 0 else { throw ValidationError("--cpus must be positive.") }
		guard
			memoryGiB > 0,
			UInt64(memoryGiB) <= UInt64.max >> 30
		else { throw ValidationError("--memory-gib is out of range.") }
		guard readinessTimeoutSeconds > 0 else { throw ValidationError("--readiness-timeout must be positive.") }
	}

	/// 進入點：見型別說明。
	internal func run() async throws {

#if arch(arm64)

		guard let manifestURL: URL = LinuxNodePaths.imageManifestURL() else {
			throw ValidationError("no golden root is configured; set MAYFLY_GOLDEN_ROOT.")
		}
		let manifest: LinuxImageManifest? = try Self.loadManifest(at: manifestURL)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let provisionScript: Data = try Self.readScript(at: provision, option: "--provision")
		let verifyScript: Data? = try verify.map { try Self.readScript(at: $0, option: "--verify") }
		let plan: LinuxImageBakePlan = try makePlan(resolver: resolver, manifest: manifest)
		let baker: LinuxImageBaker = .init(
			resolver: resolver,
			networkProvider: .init(mode: .vmnet),
			manifestURL: manifestURL
		)
		let sources: [any DispatchSourceSignal] = Self.installStopHandlers(baker: baker)
		// cancel 兼作生命週期錨點：source 若提早釋放、handler 隨之失效。
		defer { sources.forEach { $0.cancel() } }

		let options: LinuxImageBakeOptions = .init(
			cpus: cpus,
			memoryGiB: memoryGiB,
			readinessTimeout: .seconds(readinessTimeoutSeconds),
			progress: { CommandOutput.logger.log(level: .info, "\($0)") },
			output: { FileHandle.standardError.write($0) }
		)
		let result: LinuxImageBakeResult
		do {
			result = try await baker.bake(
				plan: plan,
				provisionScript: provisionScript,
				verifyScript: verifyScript,
				options: options
			)
		} catch {
			CommandOutput.logger.log(level: .error, "bake failed: \(error)")
			throw ExitCode(1)
		}
		CommandOutput.write(result.reference)
		CommandOutput.logger.log(level: .info, "registered \(plan.alias) in \(result.manifestURL.path)")
		CommandOutput.logger.log(level: .info, "start the nymph daemon again to use the new alias")

#else

		throw ValidationError("mayfly linux bake requires Apple Silicon.")

#endif

	}

	// MARK: Private

#if arch(arm64)

	/// SIGTERM／SIGINT 轉 ``LinuxImageBaker/stop()``：先 SIG_IGN 停用預設終止、再掛 DispatchSource——
	/// 容器活在本行程，預設處置會讓它與暫存檔無收斂地留下。
	/// - Parameter baker: 要停的燒製。
	/// - Returns: 掛上的 source；呼叫端持有到燒製結束再 cancel。
	private static func installStopHandlers(baker: LinuxImageBaker) -> [any DispatchSourceSignal] {
		[SIGTERM, SIGINT].map { number in
			signal(number, SIG_IGN)
			let source: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: number)
			source.setEventHandler { Task { await baker.stop() } }
			source.resume()
			return source
		}
	}

#endif

	/// 解 base、組燒製計畫；兩者的錯誤都轉成命令列的用法錯誤。
	/// - Parameters:
	///   - resolver: 解析 base 用。
	///   - manifest: 目前的別名表。
	/// - Returns: 計畫。
	/// - Throws: `ValidationError`。
	private func makePlan(resolver: LinuxImageResolver, manifest: LinuxImageManifest?) throws -> LinuxImageBakePlan {
		let baseSpec: LinuxGuestSpec
		do {
			baseSpec = try resolver.resolve(base)
		} catch {
			throw ValidationError("--base: \(error)")
		}
		do {
			return try LinuxImageBakePlan(
				alias: alias,
				base: base,
				rootfsGiB: rootfsGiB,
				baseRootfsSizeInBytes: baseSpec.rootfsSizeInBytes,
				manifest: manifest,
				replacing: replace,
				created: Date()
			)
		} catch let error as LinuxImageBakePlan.PlanError {
			throw ValidationError(error.description)
		}
	}

	/// 讀別名表；檔案不在＝還沒有這份檔。
	/// - Parameter url: 別名表路徑。
	/// - Returns: 別名表；檔案不在時為 `nil`。
	/// - Throws: `ExitCode(1)`——檔案在但讀不了或解不開，錯誤已寫進紀錄。
	private static func loadManifest(at url: URL) throws -> LinuxImageManifest? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		do {
			return try LinuxImageManifest.load(from: url)
		} catch {
			CommandOutput.logger.log(level: .error, "linux images: \(error)")
			throw ExitCode(1)
		}
	}

	/// 讀腳本檔；空檔視為錯誤。
	/// - Parameters:
	///   - path: 腳本路徑。
	///   - option: 選項名，只用於訊息。
	/// - Returns: 腳本內容。
	/// - Throws: `ValidationError`——讀不到或是空檔。
	private static func readScript(at path: String, option: String) throws -> Data {
		let data: Data
		do {
			data = try Data(contentsOf: URL(fileURLWithPath: path))
		} catch {
			throw ValidationError("\(option): cannot read \(path): \(error.localizedDescription)")
		}
		guard !data.isEmpty else { throw ValidationError("\(option): \(path) is empty.") }
		return data
	}
}
