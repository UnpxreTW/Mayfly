//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// golden 別名 → host 路徑的解析，與 clone 落點策略。**NY-3 拍板：實作 PR 附提案、
/// review 時定**——本型別即該提案，以下為建議規則，reviewer 可否決 / 調整。
///
/// **別名解析**（依序）：
/// 1. 別名是**絕對路徑**且存在 → 原樣passthrough（逃生梯，讓進階用途直接指 bundle）。
/// 2. 否則對 golden root（`MAYFLY_GOLDEN_ROOT` 環境變數、否則 `<stateDir>/golden`）解：
///    先試 `<root>/<alias>`、再試 `<root>/<alias>.bundle`；命中回該路徑，皆不存在擲
///    ``NymphError/goldenNotFound(_:)``。
///
/// **clone 落點**：`<goldenParent>/.mayfly-clones/<id>`——放在 golden 的**同一目錄之下**
/// 以硬保 CoW 的同卷契約（`clonefile(2)` 跨卷會失敗；把 clone 落在 golden 旁保證同卷）。
/// `.mayfly-clones` 前綴點、與 golden bundle 本身不混。
public struct GoldenResolver: Sendable {

	// MARK: Public

	/// golden root（別名相對解析的基底）；nil＝停用別名模式、僅接受絕對路徑。
	public let goldenRoot: URL?

	/// - Parameter goldenRoot: 別名解析基底目錄。
	public init(goldenRoot: URL?) {
		self.goldenRoot = goldenRoot
	}

	/// 從環境建構：`MAYFLY_GOLDEN_ROOT` 覆寫、否則 `<stateDir>/golden`。
	public static func fromEnvironment(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> GoldenResolver {
		if let override = environment[goldenRootEnvironmentKey], !override.isEmpty {
			return GoldenResolver(goldenRoot: URL(fileURLWithPath: override, isDirectory: true))
		}
		return GoldenResolver(goldenRoot: NymphPaths.stateDirectory(environment: environment).appending(component: "golden"))
	}

	/// golden root 覆寫用環境變數名。
	public static let goldenRootEnvironmentKey = "MAYFLY_GOLDEN_ROOT"

	/// 解析別名成 host 路徑（規則見型別註解）。
	public func resolve(_ alias: String, fileManager: FileManager = .default) throws -> URL {
		if alias.hasPrefix("/") {
			let direct = URL(fileURLWithPath: alias)
			if fileManager.fileExists(atPath: direct.path) {
				return direct
			}
			throw NymphError.goldenNotFound(alias)
		}
		guard let goldenRoot else {
			throw NymphError.goldenNotFound(alias)
		}
		let plain: URL = goldenRoot.appending(component: alias)
		if fileManager.fileExists(atPath: plain.path) {
			return plain
		}
		let suffixed: URL = goldenRoot.appending(component: alias + ".bundle")
		if fileManager.fileExists(atPath: suffixed.path) {
			return suffixed
		}
		throw NymphError.goldenNotFound(alias)
	}

	/// clone 落點：golden 同層 `.mayfly-clones/<id>`（同卷保證）。
	public func cloneDestination(forGolden goldenURL: URL, id: String) -> URL {
		goldenURL
			.deletingLastPathComponent()
			.appending(component: ".mayfly-clones")
			.appending(component: id)
	}
}
