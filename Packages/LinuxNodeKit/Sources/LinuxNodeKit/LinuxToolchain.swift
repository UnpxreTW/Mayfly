//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// Linux guest 工具鏈的版本對齊正本（單一出處、arch 無關）。
///
/// vminitd（guest agent、經 ``LinuxGuestEngine/defaultInitfsReference`` 以 OCI image 取得）
/// 與 containerization 套件同 repo 發佈；GHCR 上該 image 無 `latest` tag、只有逐版本 tag，
/// initfs tag 必須與 SwiftPM 解出的套件版本一致，否則 host 端 API 與 guest 內 vminitd
/// 產生版本 skew。三處以本常數對齊：
///
/// 1. `Package.swift` 的 containerization exact pin——不留 range、升版走人工復驗。
/// 2. ``LinuxGuestEngine/defaultInitfsReference`` 的 image tag——由本常數組出。
/// 3. `LinuxToolchainAlignmentTests` 讀 `Package.resolved` 驗 pin 與本常數一致——任一側
///    單獨升版即 fail、逼兩處同一變更對齊。
///
/// 升版程序：exact pin 與本常數同一 PR 一起改，並依 ``LinuxKernelArchive/default`` 的
/// 實測組合註記重驗 kernel（kata release）配對——kernel 與 vminitd 無共同版號，配對
/// 只能靠實測、不能靠數字相等。
public enum LinuxToolchain {

	/// containerization 套件的採用版本（同時是 vminitd OCI image tag）。
	public static let containerizationVersion: String = "0.37.0"
}
