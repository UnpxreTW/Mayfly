//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``KernelArchiveFetching`` 的真機實作：`URLSession` 下載封存 → sha256 驗證 →
/// `/usr/bin/tar` 解壓 → 複製 ``LinuxKernelArchive/innerPath`` 到 `destination`。純
/// Foundation + 系統 `tar`（bsdtar 自動辨識壓縮格式，不必顯式帶 `-J`），無 arch gate。
public struct SystemKernelArchiveFetcher: KernelArchiveFetching {

	// MARK: Public

	/// kernel 封存 fetch 的失敗面：sha256 不符（供應鏈完整性）／解壓後找不到預期路徑
	/// （封存結構跟 pin 的 ``LinuxKernelArchive/innerPath`` 對不上）／`tar` 本身失敗。
	public enum ArchiveError: Error {

		case sha256Mismatch(expected: String, actual: String)

		case missingInnerFile(String)

		case extractFailed(status: Int32, stderr: String)
	}

	public init() {}

	public func fetch(_ archive: LinuxKernelArchive, to destination: URL) async throws {
		let manager: FileManager = .default
		let workDirectory: URL = manager.temporaryDirectory.appending(component: "mayfly-kernel-\(UUID().uuidString)")
		try manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
		defer { try? manager.removeItem(at: workDirectory) }

		let archivePath: URL = workDirectory.appending(component: "archive.tar.xz")
		try await download(from: archive.archiveURL, to: archivePath)

		let actualSHA256: String = try LinuxKernelCache.sha256(of: archivePath)
		guard actualSHA256 == archive.archiveSHA256 else {
			throw ArchiveError.sha256Mismatch(expected: archive.archiveSHA256, actual: actualSHA256)
		}

		let extractDirectory: URL = workDirectory.appending(component: "extracted")
		try manager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
		try await extract(archivePath, to: extractDirectory)

		let extractedKernel: URL = extractDirectory.appending(component: archive.innerPath)
		guard manager.fileExists(atPath: extractedKernel.path) else {
			throw ArchiveError.missingInnerFile(archive.innerPath)
		}

		try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		let staging: URL = destination.deletingLastPathComponent().appending(component: ".\(destination.lastPathComponent).partial")
		try? manager.removeItem(at: staging)
		defer { try? manager.removeItem(at: staging) }
		try manager.copyItem(at: extractedKernel, to: staging)
		try manager.moveItem(at: staging, to: destination)
	}

	// MARK: Private

	/// 下載封存到本機暫存路徑（呼叫端負責清理 parent 工作目錄）。
	private func download(from remoteURL: URL, to localURL: URL) async throws {
		let (tempURL, _): (URL, URLResponse) = try await URLSession.shared.download(from: remoteURL)
		defer { try? FileManager.default.removeItem(at: tempURL) }
		try FileManager.default.moveItem(at: tempURL, to: localURL)
	}

	/// 呼叫系統 `/usr/bin/tar` 解壓（`--strip-components=1`，比照上游 kata 封存的頂層
	/// `opt/kata/...` 結構慣例）。
	private func extract(_ archivePath: URL, to destinationDirectory: URL) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			DispatchQueue.global().async {
				let process: Process = .init()
				process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
				process.arguments = ["-xf", archivePath.path, "-C", destinationDirectory.path, "--strip-components=1"]
				let stderrPipe: Pipe = .init()
				process.standardError = stderrPipe
				do {
					try process.run()
				} catch {
					continuation.resume(throwing: error)
					return
				}
				process.waitUntilExit()
				if process.terminationStatus == 0 {
					continuation.resume()
				} else {
					let stderrData: Data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
					continuation.resume(throwing: ArchiveError.extractFailed(
						status: process.terminationStatus,
						stderr: String(data: stderrData, encoding: .utf8) ?? ""
					))
				}
			}
		}
	}
}
