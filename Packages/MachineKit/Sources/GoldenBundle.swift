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

	/// 跨行程重開：驗過佈局（五件套齊 + metadata 可解）且**未標 ephemeral** 才鑄造
	/// ——可拋複本（開過機就髒）不得回鍋當 golden 再 clone，golden pristine 的前提
	/// 在跨行程重開這一路也守住。
	///
	/// **誠實界線**：這是佈局檢查點、不是 provision 證明——bundle 落盤後沒有可靠
	/// 的「注入跑過」痕跡可驗（marker 檔方案留後續）。同行程內 provision 直接回
	/// 的 ``GoldenBundle`` 才帶完整語義；load 提供的是「至少是完整 bundle、不是
	/// 任意路徑」的下限保證。
	public static func load(from bundle: URL) throws -> GoldenBundle {
		if let missing = GuestBundleLayout.firstMissingComponent(in: bundle) {
			throw GoldenBundleError.missingComponent(missing)
		}
		let metadataURL: URL = GuestBundleLayout.metadata(in: bundle)
		let metadata: BundleMetadata
		do {
			metadata = try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: metadataURL))
		} catch {
			throw GoldenBundleError.metadataUndecodable(metadataURL)
		}
		guard metadata.ephemeral != true else { throw GoldenBundleError.markedEphemeral(bundle) }
		return GoldenBundle(bundle: bundle)
	}

	/// 已注入完成的 guest bundle 目錄。
	public let bundle: URL

}
