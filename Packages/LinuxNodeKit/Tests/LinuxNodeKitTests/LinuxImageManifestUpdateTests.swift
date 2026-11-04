//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Foundation
import Testing

// MARK: - LinuxImageManifestUpdateTests

private final class LinuxImageManifestUpdateTests {

	/// 建一個暫存目錄。
	/// - Returns: 目錄路徑。
	private static func makeDirectory() throws -> URL {
		let directory: URL = FileManager.default
			.temporaryDirectory
			.appending(component: "mayfly-manifest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	/// 在新暫存目錄落一份別名表。
	/// - Parameter json: 檔案內容。
	/// - Returns: 檔案路徑。
	private static func write(_ json: String) throws -> URL {
		let url: URL = try makeDirectory().appending(component: LinuxImageManifest.fileName)
		try Data(json.utf8).write(to: url)
		return url
	}

	/// 以 JSON 物件讀回整份檔（看得到程式不認得的鍵）。
	/// - Parameter url: 檔案路徑。
	/// - Returns: 頂層物件。
	private static func object(at url: URL) throws -> [String: Any] {
		try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
	}

	/// 檔案不存在 → 新建一份只含這一條的表，讀得回來。
	@Test
	private func `missing file is created with the entry`() throws {
		let directory: URL = try Self.makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url: URL = directory.appending(component: LinuxImageManifest.fileName)
		try LinuxImageManifest.upsert(
			alias: "linux-6.3.3",
			entry: .init(reference: "mayfly.local/linux-6.3.3:t1", rootfsGiB: 16),
			in: url
		)
		let manifest: LinuxImageManifest = try LinuxImageManifest.load(from: url)
		#expect(manifest.version == LinuxImageManifest.currentVersion)
		#expect(manifest.images == ["linux-6.3.3": .init(reference: "mayfly.local/linux-6.3.3:t1", rootfsGiB: 16)])
	}

	/// 新增一條時，其他條目、頂層與條目內程式不認得的鍵全數保留。
	@Test
	private func `unknown keys and other aliases survive an insert`() throws {
		let url: URL = try Self.write(
			#"{ "version": 1, "note": "keep", "images": { "ci-lint": { "reference": "r:1", "rootfsGiB": 4, "owner": "ops" } } }"#
		)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try LinuxImageManifest.upsert(alias: "ci-new", entry: .init(reference: "r:2"), in: url)
		let object: [String: Any] = try Self.object(at: url)
		#expect(object["note"] as? String == "keep")
		let images: [String: Any] = try #require(object["images"] as? [String: Any])
		let lint: [String: Any] = try #require(images["ci-lint"] as? [String: Any])
		#expect(lint["owner"] as? String == "ops")
		#expect(lint["rootfsGiB"] as? Int == 4)
		let added: [String: Any] = try #require(images["ci-new"] as? [String: Any])
		#expect(added["reference"] as? String == "r:2")
		#expect(added["rootfsGiB"] == nil)
	}

	/// 別名已存在、沒要求覆寫 → 拒絕，檔案不動。
	@Test
	private func `existing alias is not overwritten by default`() throws {
		let original: String = #"{ "version": 1, "images": { "ci": { "reference": "r:1" } } }"#
		let url: URL = try Self.write(original)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(throws: LinuxImageManifest.UpdateError.aliasExists(path: url.path, alias: "ci")) {
			try LinuxImageManifest.upsert(alias: "ci", entry: .init(reference: "r:2"), in: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == original)
	}

	/// 要求覆寫 → 換掉參照與大小，同一條裡其他的鍵保留；大小給 `nil` 即移除。
	@Test
	private func `replacing keeps the entry's other keys`() throws {
		let url: URL = try Self.write(
			#"{ "version": 1, "images": { "ci": { "reference": "r:1", "rootfsGiB": 4, "owner": "ops" } } }"#
		)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try LinuxImageManifest.upsert(alias: "ci", entry: .init(reference: "r:2"), in: url, replacing: true)
		let images: [String: Any] = try #require(try Self.object(at: url)["images"] as? [String: Any])
		let entry: [String: Any] = try #require(images["ci"] as? [String: Any])
		#expect(entry["reference"] as? String == "r:2")
		#expect(entry["rootfsGiB"] == nil)
		#expect(entry["owner"] as? String == "ops")
	}

	/// 既有檔壞掉 → 照讀檔的錯誤回報、不在上面疊新內容。
	@Test
	private func `broken existing file is left untouched`() throws {
		let original: String = #"{ "version": 2, "images": {} }"#
		let url: URL = try Self.write(original)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(throws: LinuxImageManifest.LoadError.unsupportedVersion(path: url.path, version: 2)) {
			try LinuxImageManifest.upsert(alias: "ci", entry: .init(reference: "r:1"), in: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == original)
	}

	/// 寫出的結果驗不過（別名違規、大小非正）→ 不寫檔。
	@Test(arguments: [("team/ci", 4), ("ci", 0)])
	private func `invalid result is not written`(alias: String, rootfsGiB: Int) throws {
		let original: String = #"{ "version": 1, "images": {} }"#
		let url: URL = try Self.write(original)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(throws: LinuxImageManifest.LoadError.self) {
			try LinuxImageManifest.upsert(alias: alias, entry: .init(reference: "r:1", rootfsGiB: rootfsGiB), in: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == original)
	}
}
