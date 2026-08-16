//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 把一個 ``NymphRequest`` 分派成 ``NymphResponse`` 的伺服端契約——`SessionStore` 是主
/// 實作（見其 conformance）。抽成協議讓 ``NymphServer`` 的 socket 傳輸與 store 的編排解耦、
/// 各自可測（server 可配 fake dispatcher 驗傳輸、store 可脫離 socket 驗邏輯）。
public protocol RequestDispatching: Sendable {

	/// 處理單一請求、回單一回應（工具錯誤走 ``NymphResponse/toolError(_:)``、不擲）。
	func handle(_ request: NymphRequest) async -> NymphResponse
}

/// nymph daemon 的 Unix domain socket 伺服器：bind + listen + accept 迴圈，每條連線交一個
/// `Task` 處理（真共享——單一 client 斷線不影響其他連線或 session table）。連線走 newline-
/// delimited JSON：逐行 decode ``NymphRequest`` → `dispatcher` → 逐行 encode 回
/// ``NymphResponse``。
///
/// accept 是阻塞 syscall、跑在專屬 dispatch queue；``shutdown()`` 關 listen fd 讓 accept
/// 收斂、並移除 socket 檔。狀態（listen fd / stopped 旗標）以 `NSLock` 護、故 `@unchecked
/// Sendable`。
public final class NymphServer: @unchecked Sendable {

	// MARK: Public

	/// - Parameters:
	///   - socketPath: 監聽的 Unix socket 路徑。
	///   - dispatcher: 請求分派器（通常是 ``SessionStore``）。
	public init(socketPath: URL, dispatcher: any RequestDispatching) {
		self.socketPath = socketPath
		self.dispatcher = dispatcher
	}

	/// 綁定並開始 accept（非阻塞返回；accept 迴圈在背景 queue 跑）。
	public func start() throws {
		let fd: Int32 = try UnixSocket.listen(path: socketPath.path)
		lock.lock()
		listenFD = fd
		stopped = false
		lock.unlock()
		let dispatcher: any RequestDispatching = self.dispatcher
		acceptQueue.async { [weak self] in
			self?.acceptLoop(listenFD: fd, dispatcher: dispatcher)
		}
	}

	/// 收束：標 stopped、關 listen fd（令 accept 返回錯誤跳出迴圈）、移除 socket 檔。
	public func shutdown() {
		lock.lock()
		stopped = true
		let fd: Int32 = listenFD
		listenFD = -1
		lock.unlock()
		if fd >= 0 {
			close(fd)
		}
		try? FileManager.default.removeItem(at: socketPath)
	}

	// MARK: Private

	/// 監聽路徑。
	private let socketPath: URL

	/// 請求分派器。
	private let dispatcher: any RequestDispatching

	/// accept 迴圈的專屬 queue（阻塞 syscall、不佔協作執行緒池）。
	private let acceptQueue: DispatchQueue = .init(label: "me.unpxre.mayfly.nymph.accept")

	/// 狀態鎖。
	private let lock: NSLock = .init()

	/// listen fd（-1＝未綁 / 已關）。
	private var listenFD: Int32 = -1

	/// 收束旗標。
	private var stopped = false

	/// 是否已標收束。
	private var isStopped: Bool {
		lock.lock()
		defer { lock.unlock() }
		return stopped
	}

	/// 阻塞 accept 迴圈：每條連線交一個 `Task`。listen fd 被 ``shutdown()`` 關閉後 accept
	/// 回負值、`isStopped` 為真即跳出。
	private func acceptLoop(listenFD: Int32, dispatcher: any RequestDispatching) {
		while true {
			let clientFD: Int32 = accept(listenFD, nil, nil)
			if clientFD < 0 {
				if isStopped {
					break
				}
				continue
			}
			UnixSocket.disableSIGPIPE(clientFD)
			Task {
				await NymphServer.serve(fd: clientFD, dispatcher: dispatcher)
			}
		}
	}

	/// 服務單一連線：逐行讀請求、分派、逐行寫回應，直到對端 EOF / 寫失敗。阻塞讀寫在
	/// ``UnixSocket/ioQueue`` 上跑、async 層只 await；fd 由本函式收尾關閉。
	private static func serve(fd: Int32, dispatcher: any RequestDispatching) async {
		defer { close(fd) }
		let reader: SocketLineReader = .init(fd: fd)
		let decoder: JSONDecoder = .init()
		let encoder: JSONEncoder = .init()
		while let lineData = await UnixSocket.readLine(from: reader) {
			guard !lineData.isEmpty else {
				continue
			}
			let response: NymphResponse
			if let request = try? decoder.decode(NymphRequest.self, from: lineData) {
				response = await dispatcher.handle(request)
			} else {
				response = .toolError(ToolError(code: "bad_request", message: "malformed request"))
			}
			guard let encoded = try? encoder.encode(response) else {
				break
			}
			var payload: Data = encoded
			payload.append(0x0A)
			if await UnixSocket.write(payload, to: fd) == false {
				break
			}
		}
	}
}
