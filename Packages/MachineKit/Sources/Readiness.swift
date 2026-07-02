//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// guest provisioning readiness 的狀態。``ReadinessGate`` 從 guest serial console 的輸出
/// 推導、外送給 connect 路徑當 SSH gate 的前置訊號。
///
/// 範圍到 provisioning 完成 + IP 解出；SSH port 實際開放（要 host 對 `ip:22` 做 TCP 探測）
/// 是 connect 路徑的事、不列在此。
public enum Readiness: Sendable, Equatable {

	/// 尚未偵測到任何 readiness 訊號（初始狀態）。
	case booting

	/// guest 回報 provisioning 完成、附解出的 IP：console marker 為主、`ip=none` 或缺時以
	/// guest MAC 對 host `dhcpd_leases` 備援解析；兩者皆解不出時 `nil`。
	case provisioningReady(ip: String?)
}
