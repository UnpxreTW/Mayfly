//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging

/// 只做一件事的中介後端：門檻改讀 ``CommandOutput`` 那一份，其餘原樣轉給下游。
///
/// `Logger` 每送一行之前會先問後端的 `logLevel`，所以門檻改在什麼時候都算數——不必去管
/// ``CommandOutput/logger`` 這顆 `Logger` 是在門檻定案之前還是之後被建出來的。
internal struct LevelGate: LogHandler {

	/// 真正把行寫出去的後端。
	private var downstream: any LogHandler

	/// 這個行程的紀錄門檻。設值走 ``CommandOutput``——`Logger` 是實值型別，把門檻存在自己
	/// 身上只會改到手上那一份副本。
	internal var logLevel: Logger.Level {
		get { CommandOutput.logLevel }
		set { CommandOutput.setLogLevel(newValue) }
	}

	/// 隨附中繼資料，原樣轉給下游。
	internal var metadata: Logger.Metadata {
		get { downstream.metadata }
		set { downstream.metadata = newValue }
	}

	/// 單一中繼資料欄，原樣轉給下游。
	internal subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get { downstream[metadataKey: key] }
		set { downstream[metadataKey: key] = newValue }
	}

	/// 以下游後端組一層門檻。
	///
	/// - Parameter downstream: 真正寫出的後端。
	internal init(downstream: any LogHandler) {
		self.downstream = downstream
	}

	/// 把一則紀錄交給下游。門檻已由 `Logger` 在呼叫前比對過，這裡不再判一次。
	///
	/// - Parameter event: 要送出的事件。
	internal func log(event: LogEvent) {
		downstream.log(event: event)
	}
}
