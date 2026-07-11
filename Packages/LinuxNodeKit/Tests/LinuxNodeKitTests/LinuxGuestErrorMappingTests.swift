//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import ContainerizationError
import NymphKit
import Testing

// MARK: - LinuxGuestErrorMappingTests

private final class LinuxGuestErrorMappingTests {

	/// `.timeout` → `execTimedOut`（`wait(timeoutInSeconds:)` 逾時的 1:1 對映）。
	@Test
	private func `timeout maps to execTimedOut`() {
		let error: ContainerizationError = .init(.timeout, message: "process wait timed out")
		#expect(LinuxGuestErrorMapping.map(error) == .execTimedOut)
	}

	/// `.notFound` → `notReady`（容器目前不可定址）。
	@Test
	private func `notFound maps to notReady`() {
		let error: ContainerizationError = .init(.notFound, message: "no such container")
		#expect(LinuxGuestErrorMapping.map(error) == .notReady)
	}

	/// `.invalidState` → `notReady`（狀態不對、無法連入執行）。
	@Test
	private func `invalidState maps to notReady`() {
		let error: ContainerizationError = .init(.invalidState, message: "container not started")
		#expect(LinuxGuestErrorMapping.map(error) == .notReady)
	}

	/// `.cancelled` → `transportFailure`（執行通道中途被打斷）。
	@Test
	private func `cancelled maps to transportFailure`() {
		let error: ContainerizationError = .init(.cancelled, message: "cancelled by caller")
		#expect(LinuxGuestErrorMapping.map(error) == .transportFailure("cancelled by caller"))
	}

	/// 其餘未特別歸類的 code（如 `.internalError`）→ `internalFailure` catch-all。
	@Test
	private func `uncategorized code maps to internalFailure`() {
		let error: ContainerizationError = .init(.internalError, message: "boom")
		#expect(LinuxGuestErrorMapping.map(error) == .internalFailure("boom"))
	}

	/// 非 `ContainerizationError`（如底層 `URLSession` / `Process` 失敗）→ `transportFailure`，
	/// 帶原始錯誤描述、不吞掉資訊。
	@Test
	private func `non containerization error maps to transportFailure`() {
		struct OtherError: Error, CustomStringConvertible {
			var description: String { "other-error" }
		}
		#expect(LinuxGuestErrorMapping.map(OtherError()) == .transportFailure("other-error"))
	}
}
