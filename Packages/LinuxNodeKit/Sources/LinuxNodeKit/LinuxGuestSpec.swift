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

	/// 這個別名要配多大的 rootfs（bytes）；`nil`＝沿用引擎的預設值。
	///
	/// 只有別名表（``LinuxImageManifest``）寫了大小的條目才會有值——內建別名與 passthrough
	/// 參照都沒地方寫，也就交給引擎決定。
	public let rootfsSizeInBytes: UInt64?

	/// - Parameters:
	///   - imageReference: OCI image 參照。
	///   - kernel: 要開機用的 kernel。
	///   - rootfsSizeInBytes: rootfs 上限（bytes）；`nil`＝用引擎預設。
	public init(imageReference: String, kernel: LinuxKernelArchive, rootfsSizeInBytes: UInt64? = nil) {
		self.imageReference = imageReference
		self.kernel = kernel
		self.rootfsSizeInBytes = rootfsSizeInBytes
	}
}
