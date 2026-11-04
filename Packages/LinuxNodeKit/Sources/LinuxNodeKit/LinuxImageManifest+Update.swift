//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

extension LinuxImageManifest {

	// MARK: Public

	/// 寫入別名表時的失敗面（讀不了、解不開的既有檔仍以 ``LoadError`` 回報）。
	public enum UpdateError: Error, Equatable {

		/// 別名已存在、而呼叫端沒有要求覆寫。
		case aliasExists(path: String, alias: String)

		/// 既有檔的頂層或 `images` 不是 JSON 物件。
		case notAnObject(path: String)
	}

	/// 在別名表裡新增或覆寫一條別名，其餘內容原樣保留。
	///
	/// 這份檔是操作者手寫的，裡面可能有程式不認得的鍵（型別說明的 `- Note:`：解析時忽略）。
	/// 若先解碼成 ``LinuxImageManifest`` 再編碼回去，那些鍵會整批消失——所以這裡以 JSON 物件
	/// 層級改動：只動 `images` 底下這一條的 `reference` 與 `rootfsGiB`，同一條裡其他的鍵、
	/// 其他條目、頂層其他的鍵都不碰。
	///
	/// 寫出前先把結果當成一份新讀進來的檔驗一次（版本、別名、參照、大小），驗不過就不寫；
	/// 寫入是整檔原子替換，daemon 不會讀到寫到一半的檔。保留的是內容、不是排版：寫出的檔一律
	/// 排序鍵、兩格縮排，手寫檔原本的鍵順序與縮排會被正規化。讀、改、寫之間不上鎖——同一份檔
	/// 不要由兩個程序同時寫，後寫的會蓋掉先寫的那一條。
	///
	/// - Parameters:
	///   - alias: 別名。
	///   - entry: 這條別名的內容；`rootfsGiB` 為 `nil` 時移除既有的大小設定。
	///   - url: 別名表路徑；檔案不存在時新建一份只含這一條的表。
	///   - replacing: 別名已存在時是否覆寫。預設不覆寫——同一個別名指向另一顆映像，正在用這個
	///     別名的部署下次重啟就換了映像，這件事要呼叫端明講。
	/// - Throws: 既有檔解不開時為 ``LoadError``；別名已存在、檔案形狀不對為 ``UpdateError``；
	///   寫出的結果驗不過為 ``LoadError``（不寫檔）；讀寫檔失敗為 `Foundation` 的檔案錯誤。
	public static func upsert(alias: String, entry: Entry, in url: URL, replacing: Bool = false) throws {
		var root: [String: Any] = ["version": currentVersion, "images": [String: Any]()]
		if FileManager.default.fileExists(atPath: url.path) {
			// 既有檔先照讀檔的規則驗一次：壞掉的檔不在上面疊新內容，操作者要先修好它。
			_ = try load(from: url)
			let data: Data = try Data(contentsOf: url)
			guard let object: [String: Any] = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw UpdateError.notAnObject(path: url.path)
			}
			root = object
		}
		guard var images: [String: Any] = root["images"] as? [String: Any] else { throw UpdateError.notAnObject(path: url.path) }
		var record: [String: Any] = [:]
		if let existing: Any = images[alias] {
			guard replacing else { throw UpdateError.aliasExists(path: url.path, alias: alias) }
			guard let existingRecord: [String: Any] = existing as? [String: Any] else { throw UpdateError.notAnObject(path: url.path) }
			record = existingRecord
		}
		record["reference"] = entry.reference
		if let rootfsGiB: Int = entry.rootfsGiB {
			record["rootfsGiB"] = rootfsGiB
		} else {
			record.removeValue(forKey: "rootfsGiB")
		}
		images[alias] = record
		root["images"] = images

		let output: Data = try JSONSerialization.data(
			withJSONObject: root,
			options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		)
		let updated: LinuxImageManifest
		do {
			updated = try JSONDecoder().decode(LinuxImageManifest.self, from: output)
		} catch {
			throw LoadError.malformedJSON(path: url.path, reason: "\(error)")
		}
		try updated.validate(path: url.path)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try (output + Data("\n".utf8)).write(to: url, options: .atomic)
	}
}

// MARK: - + CustomStringConvertible

extension LinuxImageManifest.UpdateError: CustomStringConvertible {

	/// 人讀訊息：先報哪一份檔，再說為什麼沒寫。
	public var description: String {
		switch self {
		case let .aliasExists(path, alias):
			"linux image manifest \(path) already has alias \"\(alias)\"; pass the replace option to overwrite it"
		case let .notAnObject(path):
			"linux image manifest \(path) is not a JSON object with an \"images\" object"
		}
	}
}
