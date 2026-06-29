//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - GuestDiskTopology

/// `diskutil apfs list -plist` 的解碼 + 「在 attached image 上找出 guest Data 卷」的
/// 純邏輯——`GuestVolumeMounter` 的**安全關鍵核心**，不碰 Process、不需 root、
/// 可純紙上單測。
///
/// **為什麼這是命脈**：離線注入要把檔寫進 attach 後的 guest Data 卷；但同一份
/// `diskutil apfs list` 裡 **host 自己的 Data 卷也在場**（如 `Macintosh HD - Data`）。
/// 對全部卷盲找「Data role」會選到 host 卷 → 災難性寫壞主機。本型別以
/// **physical store 是否落在 attached image disk 的分割上**為安全閘先過濾，再認
/// guest 主 container（**同時**有 System 與 Data role 的那個，藉此排除 attached
/// disk 上的 iSC〔Preboot/xART〕與 Recovery container），最後回其唯一 Data 卷。
public struct GuestDiskTopology {

	/// 在 `attachedBaseDisk`（hdiutil attach 回的整顆 image disk、如 `disk8`）上找出
	/// guest 的 Data 卷 device identifier（如 `disk11s5`）。
	///
	/// **安全契約**：呼叫端**必須**傳真正 attach 出來的 image disk、絕不可傳 host 的
	/// 盤——本函式只在該盤的分割上找、不會掃到 host 卷，但它信任這個輸入。找不到唯一
	/// 解時寧可擲錯也不猜：無 guest container 擲 ``GuestVolumeMounterError/noDataVolume``、
	/// 多個 guest container 或多個 Data 卷擲 ``GuestVolumeMounterError/ambiguousVolume``。
	public func dataVolumeDeviceID(onAttachedDisk attachedBaseDisk: String) throws -> String {
		// 安全閘：只考慮 physical store 落在 attached image disk 分割上的 container。
		let onAttached = containers.filter { container in
			container.physicalStores.contains { isPartition($0.deviceIdentifier, of: attachedBaseDisk) }
		}
		// guest 主 container = 同時具 System 與 Data role（排除 attached disk 上只含
		// Preboot/xART/Recovery 的 iSC / Recovery container）。
		let guestContainers = onAttached.filter { container in
			container.hasVolume(withRole: Self.roleSystem) && container.hasVolume(withRole: Self.roleData)
		}
		guard guestContainers.count == 1, let guest = guestContainers.first else {
			throw guestContainers.isEmpty
				? GuestVolumeMounterError.noDataVolume
				: GuestVolumeMounterError.ambiguousVolume
		}
		let dataVolumes = guest.volumes.filter { $0.roles.contains(Self.roleData) }
		guard dataVolumes.count == 1, let data = dataVolumes.first else {
			throw dataVolumes.isEmpty
				? GuestVolumeMounterError.noDataVolume
				: GuestVolumeMounterError.ambiguousVolume
		}
		return data.deviceIdentifier
	}

	// MARK: Public

	/// 從 `diskutil apfs list -plist` 的輸出解碼。解碼失敗擲
	/// ``GuestVolumeMounterError/malformedTopology(underlying:)``。
	public init(plistData: Data) throws {
		do {
			self.containers = try PropertyListDecoder().decode(Root.self, from: plistData).containers
		} catch {
			throw GuestVolumeMounterError.malformedTopology(underlying: error)
		}
	}

	/// diskutil 的 role 詞彙（穩定字串）。
	private static let roleSystem = "System"

	/// diskutil 的 role 詞彙（穩定字串）。
	private static let roleData = "Data"

	/// 解碼後的 APFS container 清單。
	private let containers: [Container]

	// MARK: Private

	/// `partition` 是否為 `baseDisk` 的一個分割（`disk8s2` 之於 `disk8`）。用 `<base>s`
	/// 前綴比對、而非單純 `hasPrefix(base)`——避免 `disk8` 誤吃 `disk80s1`（另一顆盤）。
	private func isPartition(_ partition: String, of baseDisk: String) -> Bool {
		partition.hasPrefix(baseDisk + "s")
	}

}

// MARK: - Root

/// `diskutil apfs list -plist` 根層：只取 `Containers`。
private struct Root: Decodable {

	enum CodingKeys: String, CodingKey {
		case containers = "Containers"
	}

	let containers: [Container]

}

// MARK: - Container

/// 一個 APFS container：實體後盾 + 其上的卷。
private struct Container: Decodable {

	enum CodingKeys: String, CodingKey {
		case physicalStores = "PhysicalStores"
		case volumes = "Volumes"
	}

	let physicalStores: [PhysicalStore]

	let volumes: [Volume]

	/// container 內是否有任一卷帶指定 role。
	func hasVolume(withRole role: String) -> Bool {
		volumes.contains { $0.roles.contains(role) }
	}

}

// MARK: - PhysicalStore

/// container 的實體後盾分割（`DeviceIdentifier` 如 `disk8s2`）。
private struct PhysicalStore: Decodable {

	enum CodingKeys: String, CodingKey {
		case deviceIdentifier = "DeviceIdentifier"
	}

	let deviceIdentifier: String

}

// MARK: - Volume

/// container 內的一個卷：device identifier + role 集（如 `["Data"]`）。
private struct Volume: Decodable {

	enum CodingKeys: String, CodingKey {
		case deviceIdentifier = "DeviceIdentifier"
		case roles = "Roles"
	}

	let deviceIdentifier: String

	let roles: [String]

}
