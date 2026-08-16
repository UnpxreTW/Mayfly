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

// MARK: - GoldenResolverTests

private final class GoldenResolverTests {

	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "nymphtest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	/// 絕對路徑且存在 → 原樣 passthrough。
	@Test
	private func `absolute existing path passes through`() throws {
		try withTemporaryDirectory { directory in
			let resolver: GoldenResolver = .init(goldenRoot: nil)
			let resolved: URL = try resolver.resolve(directory.path)
			#expect(resolved.standardizedFileURL == directory.standardizedFileURL)
		}
	}

	/// 絕對路徑但不存在 → goldenNotFound。
	@Test
	private func `absolute missing path throws`() {
		let resolver: GoldenResolver = .init(goldenRoot: nil)
		#expect(throws: NymphError.goldenNotFound("/no/such/golden")) {
			try resolver.resolve("/no/such/golden")
		}
	}

	/// 別名對 golden root 解 `<root>/<alias>`。
	@Test
	private func `alias resolves under golden root`() throws {
		try withTemporaryDirectory { directory in
			let alias: URL = directory.appending(component: "base")
			try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
			let resolver: GoldenResolver = .init(goldenRoot: directory)
			#expect(try resolver.resolve("base").standardizedFileURL == alias.standardizedFileURL)
		}
	}

	/// 別名補 `.bundle` 後綴解 `<root>/<alias>.bundle`。
	@Test
	private func `alias resolves with bundle suffix`() throws {
		try withTemporaryDirectory { directory in
			let alias: URL = directory.appending(component: "base.bundle")
			try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
			let resolver: GoldenResolver = .init(goldenRoot: directory)
			#expect(try resolver.resolve("base").standardizedFileURL == alias.standardizedFileURL)
		}
	}

	/// 別名兩種形態皆不存在 → goldenNotFound。
	@Test
	private func `unknown alias throws`() throws {
		try withTemporaryDirectory { directory in
			let resolver: GoldenResolver = .init(goldenRoot: directory)
			#expect(throws: NymphError.goldenNotFound("ghost")) {
				try resolver.resolve("ghost")
			}
		}
	}

	/// clone 落點在 golden 同層 `.mayfly-clones/<id>`（同卷保證）。
	@Test
	private func `clone destination sits beside golden`() {
		let resolver: GoldenResolver = .init(goldenRoot: nil)
		let golden: URL = URL(fileURLWithPath: "/volume/goldens/base.bundle")
		let destination: URL = resolver.cloneDestination(forGolden: golden, id: "abc")
		#expect(destination.path == "/volume/goldens/.mayfly-clones/abc")
		#expect(destination.deletingLastPathComponent().deletingLastPathComponent().path == golden.deletingLastPathComponent().path)
	}
}
