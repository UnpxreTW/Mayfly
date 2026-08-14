//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

// MARK: - CloneRegistryTests

private final class CloneRegistryTests {

	/// 建一個一次性工作目錄、用完刪。
	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "nymphtest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	/// sweepOrphans 刪掉登記過且仍存在的目錄、回傳實刪清單、清空登記檔。
	@Test
	private func `sweep removes registered existing directories`() throws {
		try withTemporaryDirectory { directory in
			let registry: CloneRegistry = .init(fileURL: directory.appending(component: "clones.registry"))
			let cloneA: URL = directory.appending(component: "clone-a")
			let cloneB: URL = directory.appending(component: "clone-b")
			try FileManager.default.createDirectory(at: cloneA, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: cloneB, withIntermediateDirectories: true)
			registry.add(cloneA)
			registry.add(cloneB)
			let removed: [URL] = registry.sweepOrphans()
			#expect(removed.count == 2)
			#expect(!FileManager.default.fileExists(atPath: cloneA.path))
			#expect(!FileManager.default.fileExists(atPath: cloneB.path))
			// 登記檔已清空 → 再掃無事可刪。
			#expect(registry.sweepOrphans().isEmpty)
		}
	}

	/// remove 後該筆不再被 sweep 收（模擬乾淨 destroy 的 entry 不算孤兒）。
	@Test
	private func `remove drops entry from sweep`() throws {
		try withTemporaryDirectory { directory in
			let registry: CloneRegistry = .init(fileURL: directory.appending(component: "clones.registry"))
			let clone: URL = directory.appending(component: "clone-x")
			try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
			registry.add(clone)
			registry.remove(clone)
			#expect(registry.sweepOrphans().isEmpty)
			// remove 只動登記、不刪目錄本身（destroy 自己刪 clone）。
			#expect(FileManager.default.fileExists(atPath: clone.path))
		}
	}

	/// add 同一路徑兩次只留一筆（不重複登記）。
	@Test
	private func `add is idempotent`() throws {
		try withTemporaryDirectory { directory in
			let registry: CloneRegistry = .init(fileURL: directory.appending(component: "clones.registry"))
			let clone: URL = directory.appending(component: "clone-y")
			try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
			registry.add(clone)
			registry.add(clone)
			#expect(registry.sweepOrphans().count == 1)
		}
	}
}
