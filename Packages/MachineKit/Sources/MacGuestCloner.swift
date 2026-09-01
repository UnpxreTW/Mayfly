//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// golden bundle 的 copy-on-write 複製器——CI「每 job 一台乾淨 VM」生命週期的
/// prepare（clone）與 cleanup（destroy）原語。
///
/// `clonefile(2)` 對整個 bundle 目錄做 APFS CoW：clone 近乎即時、額外空間趨近 0
/// （寫入才分裂）。**同卷是硬性契約**（CoW 的物理前提）：跨卷回
/// ``MacGuestClonerError/crossVolume(source:destination:)``、不退化成數十 GB 的完整
/// 複製——要退化該由呼叫端顯式決定，不由 cloner 靜默吸收。
///
/// **身份再生**：clone 內 `metadata.json` 的 MAC **無條件換新**（locally-administered
/// unicast）——lease 反查（``ReadinessGate``）以 MAC 為鍵，兩台複本撞 MAC 會解到
/// 同一 lease、SSH 進錯台，這是引擎正確性、非禮貌問題。machineIdentifier 依先例
/// **原樣保留**：對已安裝 guest 再生識別碼的行為未經驗證（Apple 僅軟性要求併發
/// 實例不同 ID、主流 CI 工具生產環境長期併發跑同 ID 複本）；真機驗出問題再開
/// 後續切片。
public struct MacGuestCloner: Sendable {

	/// 隨機 locally-administered unicast MAC（第一個 byte：local bit 置 1、
	/// multicast bit 清 0），與 CREATE 路徑 `VZMACAddress.randomLocallyAdministered()`
	/// 同一地址類別、但純 Foundation——cloner 不為一個 MAC 掛 Virtualization 依賴，
	/// 整檔免 arch gate、可紙上測。
	public static func randomLocallyAdministeredMACAddress() -> String {
		var bytes: [UInt8] = (0 ..< 6).map { _ in UInt8.random(in: .min ... .max) }
		bytes[0] = (bytes[0] | 0b0000_0010) & 0b1111_1110
		return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
	}

	// MARK: Public

	/// 從 golden clone 一份可拋複本到 `destination`，並再生複本的 MAC。
	///
	/// 失敗即整份收掉：`clonefile` 之後任何一步出錯都移除半成品目的地，不留
	/// 「看似完整 bundle、身份卻沒換」的殘骸給下游誤用。
	public func clone(_ golden: GoldenBundle, to destination: URL) throws -> EphemeralBundle {
		let status: Int32 = clonefile(golden.bundle.path, destination.path, 0)
		if status != 0 {
			let code = errno
			throw MacGuestClonerError.map(
				errno: code,
				source: golden.bundle,
				destination: destination,
				sourceExists: FileManager.default.fileExists(atPath: golden.bundle.path)
			)
		}
		do {
			try rewriteIdentity(in: destination)
		} catch {
			try? FileManager.default.removeItem(at: destination)
			throw error
		}
		return EphemeralBundle(bundle: destination)
	}

	/// 銷毀 clone。只收 ``EphemeralBundle``——golden 在型別上就傳不進來。
	public func destroy(_ clone: EphemeralBundle) throws {
		try FileManager.default.removeItem(at: clone.bundle)
	}

	// MARK: Lifecycle

	/// - Parameter makeMACAddress: clone 身份再生所用的 MAC 產生器，預設
	///   ``randomLocallyAdministeredMACAddress()``；測試注入固定值取得確定性。
	///   預設值包一層閉包字面值：unapplied method reference 不帶 `@Sendable`、會觸發
	///   strict concurrency 轉換警告。
	public init(
		makeMACAddress: @escaping @Sendable () -> String = { MacGuestCloner.randomLocallyAdministeredMACAddress() }
	) {
		self.makeMACAddress = makeMACAddress
	}

	// MARK: Private

	/// clone 身份再生所用的 MAC 產生器。
	private let makeMACAddress: @Sendable () -> String

	/// 重寫 clone 內 `metadata.json`：換新 MAC、標 `ephemeral=true`（跨行程重開時
	/// ``EphemeralBundle/load(from:)`` 的識別依據）、其餘欄位原樣帶過。
	private func rewriteIdentity(in bundle: URL) throws {
		// propertyTypes 誤判防護：回傳型別是 URL、非 MacGuestBundleLayout
		let metadataURL: URL = MacGuestBundleLayout.metadata(in: bundle)
		var metadata = try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: metadataURL))
		metadata.macAddress = makeMACAddress()
		metadata.ephemeral = true
		try JSONEncoder().encode(metadata).write(to: metadataURL)
	}
}
