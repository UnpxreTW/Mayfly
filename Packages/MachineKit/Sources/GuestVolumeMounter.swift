//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// host 側「離線掛載 guest 磁碟、把注入檔寫進去」的 Process 薄殼——provisioning 的
/// **第三軸**（既非 create 也非 load）。把 ``GuestDiskTopology`` 的安全識別接上實際
/// `hdiutil` / `diskutil` / `chown` 命令，串成 `attach → locate → mount → enableOwnership
/// → write → detach` 的生命週期。
///
/// 做成 `actor`：狀態（attached base disk / data 卷 / 掛載點）天然隔離、步驟序列化，
/// 不需自管 queue。命令全經注入的 ``CommandRunner``——預設真跑 Process、測試注入假 runner
/// 驗命令構造與解析，不必碰真磁碟。
///
/// **root 邊界**：`attach` / `locateDataVolume` / `mount` / `detach` 不需 root（探針實證
/// owners-disabled 下可掛可讀）；但 `enableOwnership` 與 `write` 的 numeric `chown` **需
/// root**——否則注入檔帶錯 owner（host uid），guest 開機不認。兩者開頭 preflight
/// `geteuid()==0`、否則擲 ``GuestVolumeMounterError/requiresRoot``。呼叫端負責提供 root
/// （人 `sudo` / CI 本就 root），本型別不自行提權。
public actor GuestVolumeMounter {

	// MARK: Public

	/// `hdiutil attach -nomount` RAW image、解出 GUID base disk（如 `disk8`）存起。
	///
	/// install 後 VZ 可能仍持有 disk fd → attach 失敗報 busy；以 250ms 起跳的指數退避
	/// 重試到 ~5s 上限，仍 busy 擲 ``GuestVolumeMounterError/stillBusy``。`-nomount`：先
	/// 不掛、由 ``mount()`` 帶 `nobrowse` 精確掛 Data 卷。
	@discardableResult
	public func attach() async throws -> String {
		guard FileManager.default.fileExists(atPath: diskImage.path) else {
			throw GuestVolumeMounterError.notReady(step: "disk image 不存在：\(diskImage.path)")
		}
		var delayMS = retryBaseDelayMilliseconds
		var elapsedMS = 0
		let capMS = retryCapMilliseconds
		while true {
			do {
				let output = try await runner.run(
					executable: "/usr/bin/hdiutil",
					arguments: ["attach", "-nomount", "-owners", "on", "-plist", diskImage.path]
				)
				let base = try Self.parseAttachBaseDisk(output)
				attachedBaseDisk = base
				return base
			} catch let error as GuestVolumeMounterError where Self.isBusy(error) {
				guard elapsedMS < capMS else {
					throw GuestVolumeMounterError.stillBusy
				}
				try await Task.sleep(for: .milliseconds(delayMS))
				elapsedMS += delayMS
				delayMS = min(delayMS * 2, 2000)
			}
		}
	}

	/// `diskutil apfs list -plist` → ``GuestDiskTopology`` 在 attached base disk 上找出
	/// guest Data 卷的 device id（如 `disk11s5`）存起。需先 ``attach()``。
	@discardableResult
	public func locateDataVolume() async throws -> String {
		guard let base = attachedBaseDisk else {
			throw GuestVolumeMounterError.notReady(step: "attach")
		}
		let output = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"])
		let topology = try GuestDiskTopology(plistData: output)
		let identifier = try topology.dataVolumeDeviceID(onAttachedDisk: base)
		dataVolumeID = identifier
		return identifier
	}

	/// `diskutil mount -mountOptions nobrowse` 把 Data 卷 RW 掛起、回掛載點。需先
	/// ``locateDataVolume()``。`nobrowse` 讓卷不進 Finder 側欄。掛載報 locked / encrypted
	/// 擲 ``GuestVolumeMounterError/encryptedLocked``（走 Recovery fallback、非崩潰）。
	///
	/// 〔Spotlight 索引防護待議、刻意不在此處理：`noindex` 不是合法 mount 選項；也不可寫
	/// `.metadata_never_index`——那會持久進 golden、永久關掉 guest 自己的 Spotlight。正解是
	/// host 端**短暫** `mdutil -i off <mountpoint>`（不持久進卷）或靠短窗口 + 快速 detach。〕
	@discardableResult
	public func mount() async throws -> URL {
		guard let identifier = dataVolumeID else {
			throw GuestVolumeMounterError.notReady(step: "locateDataVolume")
		}
		do {
			_ = try await runner.run(
				executable: "/usr/sbin/diskutil",
				arguments: ["mount", "-mountOptions", "nobrowse", identifier]
			)
		} catch let error as GuestVolumeMounterError where Self.isLocked(error) {
			throw GuestVolumeMounterError.encryptedLocked
		}
		let info = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", identifier])
		let url = try URL(fileURLWithPath: Self.parseMountPoint(info))
		mountPoint = url
		return url
	}

	/// **需 root**：`diskutil enableOwnership`，讓後續 numeric `chown` 在這顆外掛卷生效
	/// （否則 owners-disabled、注入檔帶 host uid）。需先 ``locateDataVolume()``。
	public func enableOwnership() async throws {
		try Self.requireRoot()
		guard let identifier = dataVolumeID else {
			throw GuestVolumeMounterError.notReady(step: "locateDataVolume")
		}
		_ = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["enableOwnership", identifier])
	}

	/// **需 root**：先 `mkdir -p` 父目錄、寫 `relativePath` 的內容，再 numeric
	/// `chown <uid>:<gid>` + `chmod` 落定 owner / mode（`FileManager.setAttributes` 在外來
	/// APFS 卷會失敗、故走命令）。需先 ``mount()``（且通常先 ``enableOwnership()``）。
	///
	/// 建父目錄是因為 fresh guest 上有些注入目標的父目錄不存在（未登入帳號的
	/// `Users/<user>/Library/Preferences`、空的 `usr/local/libexec`）。`mkdir -p` 建出的
	/// 中間目錄為 **root:wheel**——系統路徑正確；落在 `Users/<user>/` 下、需 user-owned
	/// 目錄樹的目標，由 orchestrator 預先供對 owner 的目錄或另行 chown（本 primitive 只
	/// chown 寫入的檔本身、不推斷目錄 owner）。
	public func write(_ files: [InjectedFile]) async throws {
		try Self.requireRoot()
		guard let mountPoint else {
			throw GuestVolumeMounterError.notReady(step: "mount")
		}
		for file in files {
			let target = mountPoint.appending(path: file.relativePath)
			_ = try await runner.run(
				executable: "/bin/mkdir",
				arguments: ["-p", target.deletingLastPathComponent().path]
			)
			do {
				try file.contents.write(to: target, options: .atomic)
			} catch {
				throw GuestVolumeMounterError.writeFailed(relativePath: file.relativePath, underlying: error)
			}
			_ = try await runner.run(
				executable: "/usr/sbin/chown",
				arguments: ["\(file.owner.uid):\(file.owner.gid)", target.path]
			)
			_ = try await runner.run(executable: "/bin/chmod", arguments: [String(file.mode, radix: 8), target.path])
		}
	}

	/// `hdiutil detach` 卸掉整顆 attached image（連同掛上的 Data 卷）。未 attach 則 no-op。
	/// 收尾用——呼叫端通常以 `try?` 包在 defer。
	public func detach() async throws {
		guard let base = attachedBaseDisk else {
			return
		}
		_ = try await runner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", "/dev/\(base)"])
		attachedBaseDisk = nil
		dataVolumeID = nil
		mountPoint = nil
	}

	public init(
		diskImage: URL,
		runner: any CommandRunner = SystemCommandRunner(),
		retryBaseDelayMilliseconds: Int = 250,
		retryCapMilliseconds: Int = 5000
	) {
		self.diskImage = diskImage
		self.runner = runner
		self.retryBaseDelayMilliseconds = retryBaseDelayMilliseconds
		self.retryCapMilliseconds = retryCapMilliseconds
	}

	// MARK: Internal

	/// 從 `hdiutil attach -plist` 輸出解出 GUID base disk（無 slice 的整顆盤、如 `disk8`）。
	/// 手動讀 `[String: Any]`（避巢狀 Decodable 鏡像踩 swiftlint nesting）、純函式可單測。
	static func parseAttachBaseDisk(_ plistData: Data) throws -> String {
		guard
			let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
			let root = object as? [String: Any],
			let entities = root["system-entities"] as? [[String: Any]]
		else {
			throw GuestVolumeMounterError.unparseableAttachOutput
		}
		// 整顆盤 = dev-entry 形如 `/dev/disk8`（無 `s<N>` slice 尾）。
		let wholeDisk = entities.lazy.compactMap { $0["dev-entry"] as? String }.first { entry in
			entry.wholeMatch(of: /\/dev\/disk[0-9]+/) != nil
		}
		guard let devEntry = wholeDisk else {
			throw GuestVolumeMounterError.unparseableAttachOutput
		}
		return String(devEntry.dropFirst("/dev/".count))
	}

	/// 從 `diskutil info -plist <volume>` 輸出取 `MountPoint`。手動讀、純函式可單測。
	static func parseMountPoint(_ plistData: Data) throws -> String {
		guard
			let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
			let root = object as? [String: Any],
			let point = root["MountPoint"] as? String,
			!point.isEmpty
		else {
			throw GuestVolumeMounterError.notReady(step: "mount point（diskutil info 無 MountPoint）")
		}
		return point
	}

	// MARK: Private

	/// busy-like 失敗才值得 attach 重試（其餘錯立刻上拋、不空轉）。
	private static func isBusy(_ error: GuestVolumeMounterError) -> Bool {
		guard case let .commandFailed(_, _, stderr) = error else {
			return false
		}
		let lowered = stderr.lowercased()
		return lowered.contains("busy") || lowered.contains("resource temporarily unavailable") || lowered.contains("in use")
	}

	/// 掛載失敗是否因卷加密 / 鎖定（→ `encryptedLocked` 走 fallback、非通用錯）。
	private static func isLocked(_ error: GuestVolumeMounterError) -> Bool {
		guard case let .commandFailed(_, _, stderr) = error else {
			return false
		}
		let lowered = stderr.lowercased()
		return lowered.contains("locked") || lowered.contains("encrypt") || lowered.contains("passphrase")
	}

	/// 需 root 步驟的 preflight。
	private static func requireRoot() throws {
		guard geteuid() == 0 else {
			throw GuestVolumeMounterError.requiresRoot
		}
	}

	/// 待 attach 的 RAW guest disk image。
	private let diskImage: URL

	/// 命令執行器（預設真 Process、測試注入假）。
	private let runner: any CommandRunner

	/// attach busy-retry 的起始退避（ms、之後指數加倍至 2s 上限）。
	private let retryBaseDelayMilliseconds: Int

	/// attach busy-retry 的累積上限（ms、超過擲 ``GuestVolumeMounterError/stillBusy``）。
	private let retryCapMilliseconds: Int

	/// attach 後的 GUID base disk（如 `disk8`）；detach 後 nil。
	private var attachedBaseDisk: String?

	/// 識別出的 guest Data 卷 device id（如 `disk11s5`）。
	private var dataVolumeID: String?

	/// 掛載點（如 `/Volumes/Data`）。
	private var mountPoint: URL?
}
