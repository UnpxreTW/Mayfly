//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// clone 落點的持久登記——**孤兒回收**（設計 §10.5）的最小可行實作。daemon crash 後
/// 殘留的 clone 目錄無法靠記憶體 table 回收（table 已隨行程消失）；本型別把每次 spawn
/// 造出的 clone host 路徑追加到一個純文字登記檔、destroy 時移除，daemon **首啟**呼叫
/// ``sweepOrphans()`` 把登記檔內殘留（乾淨關閉會 drain 清空、有殘留即前次非正常結束）
/// 的目錄一併刪掉。
///
/// 不依賴 clone 落點命名慣例掃目錄（golden 散在各卷、無單一掃描根），改記絕對路徑——
/// 與 golden 落點無關、回收正確。登記檔 I/O 為 best-effort：丟一筆登記最壞只是漏收一個
/// 孤兒（非正確性問題），故各操作吞 I/O 錯、不擲。僅從 `SessionStore` actor 串行呼叫。
public struct CloneRegistry: Sendable {

	// MARK: Public

	/// 登記檔位置。
	public let fileURL: URL

	/// - Parameter fileURL: 登記檔路徑（`<stateDir>/clones.registry`）。
	public init(fileURL: URL) {
		self.fileURL = fileURL
	}

	/// 追加一筆 clone 路徑（spawn 落地後）。
	public func add(_ clonePath: URL) {
		var lines = readLines()
		let path = clonePath.standardizedFileURL.path
		guard !lines.contains(path) else {
			return
		}
		lines.append(path)
		writeLines(lines)
	}

	/// 移除一筆 clone 路徑（destroy 收尾後）。
	public func remove(_ clonePath: URL) {
		let path = clonePath.standardizedFileURL.path
		let lines = readLines().filter { $0 != path }
		writeLines(lines)
	}

	/// 掃孤兒：刪掉登記檔內仍存在的目錄、清空登記檔，回傳實刪清單（供日誌 / 測試）。
	@discardableResult
	public func sweepOrphans(fileManager: FileManager = .default) -> [URL] {
		let lines = readLines()
		var removed: [URL] = []
		for path in lines where fileManager.fileExists(atPath: path) {
			let url = URL(fileURLWithPath: path)
			if (try? fileManager.removeItem(at: url)) != nil {
				removed.append(url)
			}
		}
		writeLines([])
		return removed
	}

	// MARK: Private

	/// 讀登記檔為行陣列（不存在 / 不可讀回空）。
	private func readLines() -> [String] {
		guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
			return []
		}
		return content.split(whereSeparator: \.isNewline).map(String.init)
	}

	/// 覆寫登記檔（best-effort；先確保 parent 存在）。
	private func writeLines(_ lines: [String]) {
		let parent = fileURL.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
		let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
		try? body.write(to: fileURL, atomically: true, encoding: .utf8)
	}
}
