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

// MARK: - LinuxImageManifestTests

private final class LinuxImageManifestTests {

	/// 一份正常的別名表：版本、條目、rootfs 大小都照著檔案內容讀回來。
	@Test
	private func `well formed manifest loads every field`() throws {
		let url: URL = try ManifestFile.write(
			"""
			{
			  "version": 1,
			  "images": {
			    "ci-lint": { "reference": "ghcr.io/example/ci-lint@sha256:abc", "rootfsGiB": 4 },
			    "ci-swift": { "reference": "ghcr.io/example/ci-swift@sha256:def" }
			  }
			}
			"""
		)
		defer { ManifestFile.remove(url) }
		let manifest: LinuxImageManifest = try LinuxImageManifest.load(from: url)
		#expect(manifest.version == 1)
		#expect(manifest.images.count == 2)
		#expect(manifest.images["ci-lint"]?.reference == "ghcr.io/example/ci-lint@sha256:abc")
		#expect(manifest.images["ci-lint"]?.rootfsGiB == 4)
		#expect(manifest.images["ci-swift"]?.rootfsGiB == nil)
	}

	/// 未知的鍵忽略——檔案多寫東西不讓既有部署起不來。
	@Test
	private func `unknown keys are ignored`() throws {
		let url: URL = try ManifestFile.write(
			"""
			{
			  "version": 1,
			  "note": "給人看的說明",
			  "images": { "ci-lint": { "reference": "ghcr.io/example/ci-lint:1", "future": true } }
			}
			"""
		)
		defer { ManifestFile.remove(url) }
		let manifest: LinuxImageManifest = try LinuxImageManifest.load(from: url)
		#expect(manifest.images["ci-lint"]?.reference == "ghcr.io/example/ci-lint:1")
	}

	/// 版本不是這版程式認得的值 → 拒收整份檔。
	@Test
	private func `unsupported version is rejected`() throws {
		let url: URL = try ManifestFile.write(#"{ "version": 2, "images": {} }"#)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.unsupportedVersion(path: url.path, version: 2)) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// 含 `/` 的別名 → 解析時就擋（留到 runtime 會被 passthrough 規則先接走、永遠打不到）。
	@Test
	private func `alias with a slash is rejected`() throws {
		let url: URL = try ManifestFile.write(
			#"{ "version": 1, "images": { "team/ci": { "reference": "ghcr.io/example/ci:1" } } }"#
		)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.invalidAlias(path: url.path, alias: "team/ci")) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// 含 `:` 的別名同樣擋下。
	@Test
	private func `alias with a colon is rejected`() throws {
		let url: URL = try ManifestFile.write(
			#"{ "version": 1, "images": { "ci:lint": { "reference": "ghcr.io/example/ci:1" } } }"#
		)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.invalidAlias(path: url.path, alias: "ci:lint")) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// 別名開頭必須是英數字元。
	@Test
	private func `alias starting with a punctuation mark is rejected`() throws {
		let url: URL = try ManifestFile.write(
			#"{ "version": 1, "images": { "-ci": { "reference": "ghcr.io/example/ci:1" } } }"#
		)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.invalidAlias(path: url.path, alias: "-ci")) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// 點、底線、連字號在開頭之後是允許的。
	@Test
	private func `dots underscores and dashes are allowed after the first character`() throws {
		let url: URL = try ManifestFile.write(
			#"{ "version": 1, "images": { "ci-lint_6.3": { "reference": "ghcr.io/example/ci:1" } } }"#
		)
		defer { ManifestFile.remove(url) }
		let manifest: LinuxImageManifest = try LinuxImageManifest.load(from: url)
		#expect(manifest.images["ci-lint_6.3"] != nil)
	}

	/// 空的 `reference` → 擋在啟動期，不留到 spawn 當下才失敗。
	@Test
	private func `empty reference is rejected`() throws {
		let url: URL = try ManifestFile.write(#"{ "version": 1, "images": { "ci": { "reference": "" } } }"#)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.emptyReference(path: url.path, alias: "ci")) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// `rootfsGiB` 不是正整數 → 擋下。
	@Test
	private func `non positive rootfs size is rejected`() throws {
		let url: URL = try ManifestFile.write(
			#"{ "version": 1, "images": { "ci": { "reference": "ghcr.io/example/ci:1", "rootfsGiB": 0 } } }"#
		)
		defer { ManifestFile.remove(url) }
		#expect(throws: LinuxImageManifest.LoadError.invalidRootfsSize(path: url.path, alias: "ci")) {
			try LinuxImageManifest.load(from: url)
		}
	}

	/// 解不開的 JSON → `malformedJSON`，訊息帶檔案路徑。
	@Test
	private func `malformed json reports the file path`() throws {
		let url: URL = try ManifestFile.write("{ not json")
		defer { ManifestFile.remove(url) }
		let error: LinuxImageManifest.LoadError? = #expect(throws: LinuxImageManifest.LoadError.self) {
			try LinuxImageManifest.load(from: url)
		}
		#expect(error?.description.contains(url.path) == true)
	}

	/// `rootfsGiB` 換算成 bytes：4 GiB＝4 × 1024³。
	@Test
	private func `rootfs size converts gibibytes to bytes`() {
		let entry: LinuxImageManifest.Entry = .init(reference: "ghcr.io/example/ci:1", rootfsGiB: 4)
		#expect(entry.rootfsSizeInBytes == 4_294_967_296)
	}

	/// 沒寫 `rootfsGiB` 就沒有大小可帶。
	@Test
	private func `missing rootfs size converts to nil`() {
		let entry: LinuxImageManifest.Entry = .init(reference: "ghcr.io/example/ci:1")
		#expect(entry.rootfsSizeInBytes == nil)
	}
}

// MARK: - 測試輔助

/// 把一段 JSON 落成暫存檔，讓 ``LinuxImageManifest/load(from:)`` 有真的檔可讀。
private enum ManifestFile {

	/// 寫一份暫存別名表。
	/// - Parameter json: 檔案內容。
	/// - Returns: 落檔路徑。
	internal static func write(_ json: String) throws -> URL {
		let temporaryRoot: URL = FileManager.default.temporaryDirectory
		let directory: URL = temporaryRoot.appending(component: "mayfly-manifest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url: URL = directory.appending(component: LinuxImageManifest.fileName)
		try Data(json.utf8).write(to: url)
		return url
	}

	/// 清掉暫存檔所在的整個目錄。
	/// - Parameter url: ``write(_:)`` 回的路徑。
	internal static func remove(_ url: URL) {
		try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
	}
}
