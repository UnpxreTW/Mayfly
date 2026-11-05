//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation

// 觸碰 Containerization 的真容器 API——整檔 arch gate，比照 LinuxGuestControl.swift。

#if arch(arm64)

extension LinuxGuestControl {

	/// 把容器的整個 rootfs 以 GNU tar 匯出、串流寫進本機檔案（不經記憶體）。
	///
	/// 先確認容器裡的 tar 是 GNU tar（匯出參數見 ``LinuxImageBakePlan/exportArguments``，busybox
	/// tar 不認）。寫入失敗、tar 非 0 結束、或一個位元組都沒寫出，都算失敗——寫入錯誤發生在背景的
	/// IO relay，不保證傳回等待行程的這一端，所以結束後另外檢查 ``FileHandleOutputWriter/firstError``。
	///
	/// - Parameters:
	///   - layer: 目的檔；不存在就建、存在就覆寫。
	///   - standardError: tar 的 stderr 的去處。
	/// - Throws: ``LinuxImageBakeError``，或執行命令、建檔時的錯誤。
	internal func exportRootFilesystem(to layer: URL, standardError: any Writer) async throws {
		let version: BufferedOutputWriter = .init()
		let versionExit: Int32 = try await stream(
			LinuxImageBakePlan.tarVersionArguments,
			standardInput: nil,
			standardOutput: version,
			standardError: BufferedOutputWriter()
		)
		let versionText: String = String(data: version.data, encoding: .utf8) ?? ""
		guard
			versionExit == 0,
			versionText.contains(LinuxImageBakePlan.gnuTarMarker)
		else { throw LinuxImageBakeError.tarNotGNU }

		guard FileManager.default.createFile(atPath: layer.path, contents: nil) else {
			throw LinuxImageBakeError.exportIncomplete(reason: "cannot create \(layer.path)")
		}
		let handle: FileHandle = try FileHandle(forWritingTo: layer)
		let writer: FileHandleOutputWriter = .init(handle: handle, closesHandle: true)
		let exitCode: Int32
		do {
			exitCode = try await stream(
				LinuxImageBakePlan.exportArguments,
				standardInput: nil,
				standardOutput: writer,
				standardError: standardError
			)
		} catch {
			// 原本的錯誤比關檔失敗更值得回報；這裡關檔只為釋放 handle。
			try? writer.close()
			throw error
		}
		try writer.close()
		if let failure: any Error = writer.firstError {
			throw LinuxImageBakeError.exportIncomplete(reason: "writing \(layer.path) failed: \(failure)")
		}
		guard exitCode == 0 else { throw LinuxImageBakeError.exportFailed(exitCode: exitCode) }
		guard writer.bytesWritten > 0 else { throw LinuxImageBakeError.exportIncomplete(reason: "tar produced no output") }
	}
}

#endif
