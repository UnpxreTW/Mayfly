//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 燒映像時容器的規格與輸出去處。
public struct LinuxImageBakeOptions: Sendable {

	/// 容器的 vCPU 數。
	public var cpus: Int

	/// 容器的記憶體（GiB）。
	public var memoryGiB: Int

	/// 每台容器的 readiness 等待上限。
	public var readinessTimeout: Duration

	/// 進度訊息（一則一行、不含換行）的去處。
	public var progress: @Sendable (String) -> Void

	/// 容器內命令的 stdout／stderr 原樣轉出的去處（rootfs 匯出的 stdout 除外）。
	public var output: @Sendable (Data) -> Void

	/// - Parameters:
	///   - cpus: 容器的 vCPU 數。
	///   - memoryGiB: 容器的記憶體（GiB）。
	///   - readinessTimeout: 每台容器的 readiness 等待上限。
	///   - progress: 進度訊息的去處；預設丟棄。
	///   - output: 容器內命令輸出的去處；預設丟棄。
	public init(
		cpus: Int = 4,
		memoryGiB: Int = 4,
		readinessTimeout: Duration = .seconds(180),
		progress: @escaping @Sendable (String) -> Void = { _ in },
		output: @escaping @Sendable (Data) -> Void = { _ in }
	) {
		self.cpus = cpus
		self.memoryGiB = memoryGiB
		self.readinessTimeout = readinessTimeout
		self.progress = progress
		self.output = output
	}
}
