//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 從 ``GoldenBundle`` clone 出來的可拋 guest bundle marker。與 golden 在型別上
/// 區隔：``GuestCloner/destroy(_:)`` 只收 EphemeralBundle——「把 golden 當可拋
/// 複本刪掉」這整類事故在編譯期就不成立。CI 的 per-job 生命週期（prepare 時
/// clone、cleanup 時 destroy）拿到的都是這個型別。
///
/// `init` 不公開：同模組只有 ``GuestCloner``（clone 時）與 ``load(from:)``（跨行程
/// 重開、驗 metadata 的 ephemeral 標記）兩條鑄造途徑，下游模組無從把任意路徑包成
/// 可銷毀的複本——延續 ``GoldenBundle`` 的型別紀律。
public struct EphemeralBundle: Sendable {

	/// 跨行程重開：驗過佈局（五件套齊）且 metadata 標 `ephemeral=true` 才鑄造。
	/// CLI 的 `run` / `destroy` 在 clone 之外的行程收路徑時走這裡——golden 沒有
	/// ephemeral 標記、包不成 EphemeralBundle，`destroy` 因此跨行程也刪不到 golden。
	public static func load(from bundle: URL) throws -> EphemeralBundle {
		if let missing = GuestBundleLayout.firstMissingComponent(in: bundle) {
			throw EphemeralBundleError.missingComponent(missing)
		}
		let metadataURL: URL = GuestBundleLayout.metadata(in: bundle)
		let metadata: BundleMetadata
		do {
			metadata = try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: metadataURL))
		} catch {
			throw EphemeralBundleError.metadataUndecodable(metadataURL)
		}
		guard metadata.ephemeral == true else { throw EphemeralBundleError.notEphemeral(bundle) }
		return EphemeralBundle(bundle: bundle)
	}

	/// clone 出來的 guest bundle 目錄。
	public let bundle: URL
}
