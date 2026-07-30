//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit
import SwiftUI
import Testing

@testable import MayflyUI

// MARK: - SessionPresentationTests

private final class SessionPresentationTests {

	/// 四態的名稱逐一釘死——只驗「四個值互不相同」的話，把兩態對調照樣全綠。
	@Test
	private func `each session state maps to its own name`() {
		#expect(SessionState.idle.displayName == "閒置")
		#expect(SessionState.booting.displayName == "開機中")
		#expect(SessionState.ready.displayName == "就緒")
		#expect(SessionState.stopped.displayName == "已停止")
	}

	/// 符號同理逐一釘死。
	@Test
	private func `each session state maps to its own symbol`() {
		#expect(SessionState.idle.symbolName == "circle")
		#expect(SessionState.booting.symbolName == "circle.dotted")
		#expect(SessionState.ready.symbolName == "circle.fill")
		#expect(SessionState.stopped.symbolName == "stop.circle")
	}

	/// 只有就緒態用實心，跟隨「填滿代表啟用中」的系統慣例。
	@Test
	private func `only the ready state uses a filled symbol`() {
		#expect(SessionState.ready.symbolName.hasSuffix(".fill"))
		#expect(!SessionState.idle.symbolName.hasSuffix(".fill"))
		#expect(!SessionState.booting.symbolName.hasSuffix(".fill"))
		#expect(!SessionState.stopped.symbolName.hasSuffix(".fill"))
	}

	/// 顏色逐態釘死：橘綠對調在一瞥距離下讀不出來，也沒有別的訊號攔得住。
	@Test
	private func `each session state carries its own tint`() {
		#expect(SessionState.idle.tint == .secondary)
		#expect(SessionState.booting.tint == .orange)
		#expect(SessionState.ready.tint == .green)
		#expect(SessionState.stopped.tint == .secondary)
	}

	/// 存活時間分三段折算，邊界值釘死。
	@Test
	private func `uptime folds seconds into minutes and hours`() {
		#expect(SessionFormatting.uptime(seconds: 0) == "0 s")
		#expect(SessionFormatting.uptime(seconds: 59) == "59 s")
		#expect(SessionFormatting.uptime(seconds: 61) == "1 m 1 s")
		#expect(SessionFormatting.uptime(seconds: 3599) == "59 m 59 s")
		#expect(SessionFormatting.uptime(seconds: 3661) == "1 h 1 m")
	}

	/// 負值不該印出負秒數。
	@Test
	private func `uptime clamps negative input`() {
		#expect(SessionFormatting.uptime(seconds: -5) == "0 s")
	}

	/// 記憶體帶單位；IP 未解出時給破折號、不留空格。
	@Test
	private func `memory carries its unit and an unresolved address shows a dash`() {
		#expect(SessionFormatting.memory(gib: 4) == "4 GiB")
		#expect(SessionFormatting.address("192.168.64.10") == "192.168.64.10")
		#expect(SessionFormatting.address(nil) == "—")
	}

	/// 自動更新出狀況時，兩型措辭都必須明講資料可能過期——這是清單留在畫面上的前提，
	/// 少了它就等於拿舊資料冒充現況。
	@Test
	private func `both background issue notes admit the data may be stale`() {
		let stalled: String = SessionLibraryModel.BackgroundIssue.stalled.note
		let failed: String = SessionLibraryModel.BackgroundIssue
			.failed(.unreachable(endpoint: SessionFixtures.endpoint(socketPresent: false), detail: nil))
			.note
		#expect(stalled.contains("可能不是當下狀態"))
		#expect(failed.contains("可能不是當下狀態"))
		#expect(stalled != failed)
	}
}
