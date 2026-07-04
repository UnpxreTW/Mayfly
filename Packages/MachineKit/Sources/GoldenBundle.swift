//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 已 provisioned 的 guest bundle marker。與「剛裝好、未注入」的裸 bundle 在型別上區隔
/// ——run 路徑可在編譯期要求一份「保證 provisioning 跑過」的 image，延續 create-vs-load
/// 的型別紀律（再加一層 provisioned-vs-unprovisioned）。
///
/// `init` 不公開：同模組只有 ``GuestProvisioner``（provision 完成時）與 ``load(from:)``
/// （跨行程重開檢查點）兩條鑄造途徑，下游模組（CLI / app / MCP）只能消費。
public struct GoldenBundle: Sendable {

	/// 跨行程重開：驗過佈局（五件套齊 + metadata 可解）後鑄造。
	///
	/// **誠實界線**：這是佈局檢查點、不是 provision 證明——bundle 落盤後沒有可靠
	/// 的「注入跑過」痕跡可驗（marker 檔方案留後續）。同行程內 provision 直接回
	/// 的 ``GoldenBundle`` 才帶完整語義；load 提供的是「至少是完整 bundle、不是
	/// 任意路徑」的下限保證。
	public static func load(from bundle: URL) throws -> GoldenBundle {
		let components: [URL] = [
			GuestBundleLayout.diskImage(in: bundle),
			GuestBundleLayout.auxiliaryStorage(in: bundle),
			GuestBundleLayout.machineIdentifier(in: bundle),
			GuestBundleLayout.hardwareModel(in: bundle),
			GuestBundleLayout.metadata(in: bundle)
		]
		for component in components where !FileManager.default.fileExists(atPath: component.path) {
			throw GoldenBundleError.missingComponent(component)
		}
		let metadataURL: URL = GuestBundleLayout.metadata(in: bundle)
		do {
			_ = try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: metadataURL))
		} catch {
			throw GoldenBundleError.metadataUndecodable(metadataURL)
		}
		return GoldenBundle(bundle: bundle)
	}

	/// 已注入完成的 guest bundle 目錄。
	public let bundle: URL

}
