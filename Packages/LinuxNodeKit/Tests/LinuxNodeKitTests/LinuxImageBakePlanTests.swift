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

// MARK: - LinuxImageBakePlanTests

private final class LinuxImageBakePlanTests {

	/// 固定的燒製時刻：2026-11-04 12:34:56 UTC。
	private static let created: Date = .init(timeIntervalSince1970: 1_793_795_696)

	/// 只有一條 `ci-swift` 的別名表。
	private static let manifest: LinuxImageManifest = .init(
		version: LinuxImageManifest.currentVersion,
		images: ["ci-swift": .init(reference: "ghcr.io/example/ci-swift@sha256:abc", rootfsGiB: 16)]
	)

	/// 以預設值組一份計畫。
	/// - Parameters:
	///   - alias: 別名。
	///   - rootfsGiB: 指定的 rootfs 大小。
	///   - baseRootfsSizeInBytes: base 的 rootfs 大小。
	///   - replacing: 是否覆寫。
	/// - Returns: 計畫。
	private static func plan(
		alias: String = "linux-6.3.3",
		rootfsGiB: Int? = nil,
		baseRootfsSizeInBytes: UInt64? = nil,
		replacing: Bool = false
	) throws -> LinuxImageBakePlan {
		try LinuxImageBakePlan(
			alias: alias,
			base: "ci-swift",
			rootfsGiB: rootfsGiB,
			baseRootfsSizeInBytes: baseRootfsSizeInBytes,
			manifest: manifest,
			replacing: replacing,
			created: created
		)
	}

	/// 標籤＝`b`＋UTC 時刻；參照掛在本機網域、別名轉小寫。
	@Test
	private func `reference uses the local domain, the lowercased alias, and a UTC timestamp tag`() throws {
		#expect(LinuxImageBakePlan.tag(for: Self.created) == "b20261104123456")
		let plan: LinuxImageBakePlan = try Self.plan(alias: "Linux-6.3.3")
		#expect(plan.reference == "mayfly.local/linux-6.3.3:b20261104123456")
		#expect(plan.alias == "Linux-6.3.3")
		#expect(plan.manifestEntry.reference == plan.reference)
	}

	/// 未指定大小時沿用 base 的大小；不足 1 GiB 的零頭進位。
	@Test
	private func `rootfs size follows the base unless given`() throws {
		#expect(try Self.plan(baseRootfsSizeInBytes: 16 << 30).rootfsGiB == 16)
		#expect(try Self.plan(baseRootfsSizeInBytes: (16 << 30) + 1).rootfsGiB == 17)
		#expect(try Self.plan(rootfsGiB: 8, baseRootfsSizeInBytes: 16 << 30).rootfsGiB == 8)
		#expect(try Self.plan().rootfsGiB == nil)
		#expect(try Self.plan(rootfsGiB: 8).rootfsSizeInBytes == 8 << 30)
		#expect(try Self.plan(rootfsGiB: 8).manifestEntry.rootfsGiB == 8)
	}

	/// 不合規的大小在開工前擋下。
	@Test
	private func `out of range rootfs size is rejected`() {
		#expect(throws: LinuxImageBakePlan.PlanError.invalidRootfsSize(0)) {
			try Self.plan(rootfsGiB: 0)
		}
		#expect(throws: LinuxImageBakePlan.PlanError.invalidRootfsSize(Int.max)) {
			try Self.plan(rootfsGiB: Int.max)
		}
	}

	/// 別名不合字元規則、或組不出映像名的，開工前擋下。
	@Test
	private func `invalid alias is rejected`() {
		#expect(throws: LinuxImageBakePlan.PlanError.invalidAlias("a/b")) {
			try Self.plan(alias: "a/b")
		}
		#expect(throws: LinuxImageBakePlan.PlanError.invalidAlias("trailing-")) {
			try Self.plan(alias: "trailing-")
		}
	}

	/// 已有同名別名：不覆寫就擋下，要求覆寫則放行。
	@Test
	private func `existing alias needs replacing`() throws {
		#expect(throws: LinuxImageBakePlan.PlanError.aliasExists("ci-swift")) {
			try Self.plan(alias: "ci-swift")
		}
		#expect(try Self.plan(alias: "ci-swift", replacing: true).alias == "ci-swift")
	}

	/// 只差大小寫的別名會落在同一個參照上，覆寫也不放行。
	@Test
	private func `alias differing only in case is rejected`() {
		#expect(throws: LinuxImageBakePlan.PlanError.aliasCaseClash(alias: "CI-Swift", existing: "ci-swift")) {
			try Self.plan(alias: "CI-Swift", replacing: true)
		}
	}

	/// 既有別名含大寫、新別名全小寫時同樣擋下。
	@Test
	private func `lowercase alias clashing with a mixed-case existing alias is rejected`() {
		let manifest: LinuxImageManifest = .init(
			version: LinuxImageManifest.currentVersion,
			images: ["CI-Lint": .init(reference: "ghcr.io/example/ci-lint@sha256:abc")]
		)
		#expect(throws: LinuxImageBakePlan.PlanError.aliasCaseClash(alias: "ci-lint", existing: "CI-Lint")) {
			try LinuxImageBakePlan(
				alias: "ci-lint",
				base: "alpine",
				rootfsGiB: nil,
				baseRootfsSizeInBytes: nil,
				manifest: manifest,
				replacing: false,
				created: Self.created
			)
		}
	}

	/// 還沒有別名表時，任何合規別名都可用。
	@Test
	private func `no manifest accepts any valid alias`() throws {
		let plan: LinuxImageBakePlan = try LinuxImageBakePlan(
			alias: "ci-swift",
			base: "alpine",
			rootfsGiB: nil,
			baseRootfsSizeInBytes: nil,
			manifest: nil,
			replacing: false,
			created: Self.created
		)
		#expect(plan.base == "alpine")
	}

	/// 匯出命令：選項都在成員 `.` 之前，排除清單完整帶上。
	@Test
	private func `export arguments put every option before the member`() {
		let arguments: [String] = LinuxImageBakePlan.exportArguments
		#expect(arguments.first == "tar")
		#expect(arguments.last == ".")
		#expect(arguments.filter { $0 == "." }.count == 1)
		for option in ["--create", "--file=-", "--one-file-system", "--numeric-owner", "--xattrs", "--directory=/"] {
			#expect(arguments.contains(option))
		}
		#expect(arguments.filter { $0.hasPrefix("--exclude=") } == [
			"--exclude=./tmp/*",
			"--exclude=./var/tmp/*",
			"--exclude=./etc/resolv.conf"
		])
	}

	/// 腳本落點在 `/tmp` 下：匯出時排除、不進映像。
	@Test
	private func `staged scripts live under an excluded directory`() {
		#expect(LinuxImageBakePlan.stagedProvisionPath.hasPrefix("/tmp/"))
		#expect(LinuxImageBakePlan.stagedVerifyPath.hasPrefix("/tmp/"))
		#expect(LinuxImageBakePlan.excludedMembers.contains("./tmp/*"))
	}

	/// 寫腳本的命令把落點當 `$0` 傳、不拼進命令字串。
	@Test
	private func `staging passes the path as an argument`() {
		let arguments: [String] = LinuxImageBakePlan.stageArguments(path: "/tmp/x y")
		#expect(arguments.count == 4)
		#expect(arguments.last == "/tmp/x y")
		#expect(!arguments[2].contains("/tmp/x y"))
		#expect(LinuxImageBakePlan.runScriptArguments(path: "/tmp/x") == ["/bin/bash", "-l", "/tmp/x"])
	}

	/// 冒煙以登入 shell 跑、遇錯即停，並逐條驗映像的硬需求。
	@Test
	private func `smoke script checks the image requirements`() {
		let arguments: [String] = LinuxImageBakePlan.smokeArguments
		#expect(Array(arguments.prefix(2)) == ["/bin/bash", "-lc"])
		let script: String = LinuxImageBakePlan.smokeScript
		#expect(script.hasPrefix("set -eux\n"))
		let requirements: [String] = [
			"id -un",
			"uname -m",
			"/etc/passwd",
			"command -v git",
			"ca-certificates.crt",
			"/bin/true",
			"/bin/sleep",
			"base64",
			"dirname",
			"chmod",
			"umask",
			"mkdir -p /tmp/"
		]
		for requirement in requirements {
			#expect(script.contains(requirement), "missing \(requirement)")
		}
	}
}
