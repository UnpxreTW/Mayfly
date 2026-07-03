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
/// `init` 不公開：只有同模組的 ``GuestCloner`` 鑄得出 EphemeralBundle，下游模組
/// 只能從 clone 取得、無從把任意路徑包成可銷毀的複本——延續
/// ``GoldenBundle`` 的型別紀律。
public struct EphemeralBundle: Sendable {

	/// clone 出來的 guest bundle 目錄。
	public let bundle: URL
}
