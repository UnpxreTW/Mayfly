//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// ``LinuxImageResolver/resolve(_:)`` 的產物：OCI image 參照 ＋ 要配的 kernel。
public struct LinuxGuestSpec: Sendable, Equatable {

	/// OCI image 參照（如 `docker.io/library/alpine:3`）。
	public let imageReference: String

	/// 要開機用的 kernel。
	public let kernel: LinuxKernelArchive

	public init(imageReference: String, kernel: LinuxKernelArchive) {
		self.imageReference = imageReference
		self.kernel = kernel
	}
}
