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

/// 傳輸層失敗——與 ``NymphError``（工具層）分開：這裡是「連 / 綁 socket 本身失敗」，
/// 尚談不到工具語義。帶 `errno` 字串供 triage。
public enum NymphTransportError: Error, Sendable, Equatable {

	/// socket path 超過 `sun_path` 上限（104 bytes）。
	case pathTooLong(String)

	/// `socket(2)` 失敗。
	case socketCreationFailed(String)

	/// `bind(2)` 失敗（socket 檔落點）。
	case bindFailed(String, String)

	/// `listen(2)` 失敗。
	case listenFailed(String)

	/// `connect(2)` 失敗（daemon 未起 / socket 不存在）。
	case connectFailed(String, String)

	/// 連線在收到完整回應前關閉。
	case connectionClosed
}

extension NymphTransportError: CustomStringConvertible {

	/// 人讀訊息——CLI（`NymphClientSupport`）與 MCP shim（`NymphToolInvoker`）共用同一份措辭，
	/// 不各自維護一份 switch。
	public var description: String {
		switch self {
		case .connectFailed:
			return "cannot reach the nymph daemon (is `mayfly nymph` running?)"

		case .connectionClosed:
			return "connection closed before a response arrived"

		case let .pathTooLong(path):
			return "socket path too long: \(path)"

		case let .bindFailed(path, detail):
			return "bind failed at \(path): \(detail)"

		case let .socketCreationFailed(detail):
			return "socket() failed: \(detail)"

		case let .listenFailed(detail):
			return "listen() failed: \(detail)"
		}
	}
}

/// POSIX Unix domain socket 的最小零依賴封裝（`AF_UNIX` / `SOCK_STREAM`）——daemon 核心
/// 走我方協議、不引 NIO。只做 listen / connect / sockaddr 組裝與 SIGPIPE 抑制；讀寫分幀
/// 由 ``NymphServer`` / ``NymphClient`` 以 `FileHandle` 行流處理。純 POSIX、無 arch gate。
enum UnixSocket {

	/// `sun_path` 的容量（macOS = 104；含結尾 NUL）。
	static var maxPathLength: Int {
		MemoryLayout.size(ofValue: sockaddr_un().sun_path)
	}

	/// 建 listen socket：確保 parent dir、清舊 socket 檔、bind、listen。回 listen fd。
	static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
		let parent = (path as NSString).deletingLastPathComponent
		try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
		let fd: Int32 = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else {
			throw NymphTransportError.socketCreationFailed(errnoString())
		}
		var addr: sockaddr_un = try makeSockaddr(path: path)
		unlink(path)
		let bound: Int32 = withUnsafePointer(to: &addr) { raw in
			raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
				bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard bound == 0 else {
			close(fd)
			throw NymphTransportError.bindFailed(path, errnoString())
		}
		guard Darwin.listen(fd, backlog) == 0 else {
			close(fd)
			throw NymphTransportError.listenFailed(errnoString())
		}
		return fd
	}

	/// 連上既有 socket：回已連 fd（SIGPIPE 已抑制）。
	static func connect(path: String) throws -> Int32 {
		let fd: Int32 = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else {
			throw NymphTransportError.socketCreationFailed(errnoString())
		}
		disableSIGPIPE(fd)
		var addr: sockaddr_un = try makeSockaddr(path: path)
		let connected: Int32 = withUnsafePointer(to: &addr) { raw in
			raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
				Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard connected == 0 else {
			close(fd)
			throw NymphTransportError.connectFailed(path, errnoString())
		}
		return fd
	}

	/// 對 fd 關掉 SIGPIPE（`SO_NOSIGPIPE`）——對端關閉時 write 應收 `EPIPE`、不能讓訊號打死
	/// 常駐 daemon。
	static func disableSIGPIPE(_ fd: Int32) {
		var enabled: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
	}

	/// 組 `sockaddr_un`：family + 把 path 複製進定長 `sun_path`（結尾 NUL）。
	static func makeSockaddr(path: String) throws -> sockaddr_un {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let bytes: [UInt8] = Array(path.utf8)
		guard bytes.count < maxPathLength else {
			throw NymphTransportError.pathTooLong(path)
		}
		withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
			tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { dst in
				for (index, byte) in bytes.enumerated() {
					dst[index] = CChar(bitPattern: byte)
				}
				dst[bytes.count] = 0
			}
		}
		return addr
	}

	/// 現時 `errno` 的人讀字串。
	static func errnoString() -> String {
		String(cString: strerror(errno))
	}

	/// 阻塞 I/O 的專屬並行 queue——`read` / `write` 是阻塞 syscall，放這裡跑（各連線各佔一
	/// 條 queue thread），async 層只 await continuation、不佔協作執行緒池（避免測試並行跑時
	/// 把 cooperative pool 卡死）。
	static let ioQueue: DispatchQueue = .init(label: "me.unpxre.mayfly.nymph.io", attributes: .concurrent)

	/// async 讀一行（阻塞讀在 ``ioQueue`` 上跑、續傳回主流程）。EOF 無殘餘回 nil。
	static func readLine(from reader: SocketLineReader) async -> Data? {
		await withCheckedContinuation { continuation in
			ioQueue.async { continuation.resume(returning: reader.next()) }
		}
	}

	/// async 全量寫（阻塞寫在 ``ioQueue`` 上跑）。對端關閉 / 寫失敗回 false。
	static func write(_ data: Data, to fd: Int32) async -> Bool {
		await withCheckedContinuation { continuation in
			ioQueue.async { continuation.resume(returning: writeAll(fd: fd, data)) }
		}
	}

	/// 阻塞全量寫：短寫迴圈補齊；任一次 write ≤ 0（EPIPE / 對端關閉）回 false。
	static func writeAll(fd: Int32, _ data: Data) -> Bool {
		data.withUnsafeBytes { raw -> Bool in
			guard let base = raw.baseAddress else {
				return true
			}
			var offset = 0
			while offset < raw.count {
				let written: Int = Darwin.write(fd, base + offset, raw.count - offset)
				if written <= 0 {
					return false
				}
				offset += written
			}
			return true
		}
	}
}

/// 一條連線的阻塞式行讀取器：緩衝 `read` 的分塊、以 `\n` 切行（跨 read 邊界的半行留緩衝、
/// 下次補齊）。單一連線由單一流程串行 next()（serve / send 逐行 await），故 `@unchecked
/// Sendable`——跨進 ``UnixSocket/ioQueue`` 執行、無並發存取。
final class SocketLineReader: @unchecked Sendable {

	init(fd: Int32) {
		self.fd = fd
	}

	/// 阻塞取下一行（去掉換行）。緩衝已無整行且 EOF：有殘餘回殘餘、無則回 nil。
	func next() -> Data? {
		while true {
			if let newlineIndex = buffer.firstIndex(of: 0x0A) {
				let line: Data = buffer.subdata(in: buffer.startIndex ..< newlineIndex)
				buffer.removeSubrange(buffer.startIndex ... newlineIndex)
				return line
			}
			if reachedEOF {
				guard !buffer.isEmpty else {
					return nil
				}
				let rest: Data = buffer
				buffer.removeAll(keepingCapacity: false)
				return rest
			}
			var chunk: [UInt8] = .init(repeating: 0, count: 4096)
			let count: Int = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
			if count > 0 {
				buffer.append(contentsOf: chunk[0 ..< count])
			} else {
				reachedEOF = true
			}
		}
	}

	private let fd: Int32

	private var buffer: Data = .init()

	private var reachedEOF = false
}
