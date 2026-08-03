//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationExtras
import Foundation
@testable import LinuxNodeKit

/// 極簡上鎖封套——fake 需在跨隔離（`async` 呼叫）間累積呼叫紀錄，用 NSLock 護一份可變
/// 值即可，避免測試依賴具體並行原語（同 NymphKitTests/Support/Fakes.swift 的既有模式）。
final class Locked<Value>: @unchecked Sendable {

	init(_ value: Value) {
		self.value = value
	}

	@discardableResult
	func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try body(&value)
	}

	var current: Value {
		withLock { $0 }
	}

	private let lock: NSLock = .init()

	private var value: Value
}

/// 假 ``KernelArchiveFetching``：記錄收到的 archive / destination，可配成功寫入
/// 佔位檔或擲固定錯誤——把 ``LinuxKernelProvisioner`` 的 fetch-on-demand 編排與真連網
/// / 真 tar 解壓隔開來測。
final class FakeKernelArchiveFetcher: KernelArchiveFetching, @unchecked Sendable {

	init(failure: (any Error)? = nil, writtenContents: String = "fake-kernel-bytes") {
		self.failure = failure
		self.writtenContents = writtenContents
	}

	struct FetchCall {

		let archive: LinuxKernelArchive

		let destination: URL
	}

	let calls: Locked<[FetchCall]> = .init([])

	func fetch(_ archive: LinuxKernelArchive, to destination: URL) async throws {
		calls.withLock { $0.append(FetchCall(archive: archive, destination: destination)) }
		if let failure {
			throw failure
		}
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(writtenContents.utf8).write(to: destination)
	}

	private let failure: (any Error)?

	private let writtenContents: String
}

/// 假 `Interface`：只帶測試會斷言的欄位，其餘走協定 extension 的預設值。
struct FakeInterface: Interface {

	let ipv4Address: CIDRv4

	let ipv4Gateway: IPv4Address?

	let macAddress: MACAddress?

	let mtu: UInt32

	init(ipv4Address: CIDRv4, ipv4Gateway: IPv4Address? = nil, macAddress: MACAddress? = nil, mtu: UInt32) {
		self.ipv4Address = ipv4Address
		self.ipv4Gateway = ipv4Gateway
		self.macAddress = macAddress
		self.mtu = mtu
	}
}

/// 假 ``ContainerInterfaceAllocating``：依序發出預備好的位址、記下每次收到的
/// id 與 MTU，並模擬真配發器的三條語義——「同一 id 重複配發即錯」「配額用盡即錯」
/// 「交還後位址可再用」——讓 ``LinuxContainerNetwork`` 的共用與 MTU 政策不必真開 vmnet
/// 網路就能測。
///
/// 全部可變狀態收在單一 ``Locked`` 裡：本假物件會被併發呼叫，若靠受測型別的那把鎖才安全，
/// 就等於用要測的東西替測具自保。
final class FakeInterfaceAllocator: ContainerInterfaceAllocating, @unchecked Sendable {

	/// 對齊真配發器的 `ContainerizationError(.exists)`：同一 id 配第二次即錯。
	struct DuplicateAllocation: Error {

		let containerID: String
	}

	/// 對齊真配發器的 `AllocatorError.allocatorFull`：位址池空了即錯、不是回 `nil`。
	struct Exhausted: Error {

		let containerID: String
	}

	struct MakeCall: Equatable {

		let containerID: String

		let mtu: UInt32
	}

	init(addresses: [String]) {
		self.state = .init(State(available: addresses))
	}

	var makeCalls: [MakeCall] {
		state.current.makeCalls
	}

	var discardCalls: [String] {
		state.current.discardCalls
	}

	func makeInterface(_ containerID: String, mtu: UInt32) throws -> (any Interface)? {
		let address: String = try state.withLock { state in
			state.makeCalls.append(MakeCall(containerID: containerID, mtu: mtu))
			guard state.issued[containerID] == nil else {
				throw DuplicateAllocation(containerID: containerID)
			}
			guard !state.available.isEmpty else {
				throw Exhausted(containerID: containerID)
			}
			let next: String = state.available.removeFirst()
			state.issued[containerID] = next
			return next
		}
		let cidr: CIDRv4 = try .init(address)
		return FakeInterface(ipv4Address: cidr, mtu: mtu)
	}

	func discardInterface(_ containerID: String) throws {
		state.withLock { state in
			state.discardCalls.append(containerID)
			guard let address: String = state.issued.removeValue(forKey: containerID) else { return }
			state.available.append(address)
		}
	}

	private struct State {

		var available: [String]

		var issued: [String: String] = [:]

		var makeCalls: [MakeCall] = []

		var discardCalls: [String] = []
	}

	private let state: Locked<State>
}

/// 假 ``ContainerInterfaceAllocating``：永遠回 `nil`、永不擲錯。用來釘住
/// ``LinuxContainerNetwork`` 對「語義不同的實作」的防線——`nil` 必須就地轉成擲錯，
/// 不得照傳給會靜默跳過它的上游。
struct NilInterfaceAllocator: ContainerInterfaceAllocating {

	func makeInterface(_ containerID: String, mtu: UInt32) throws -> (any Interface)? {
		nil
	}

	func discardInterface(_ containerID: String) throws {}
}
