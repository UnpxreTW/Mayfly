//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

// MARK: - KeychainPreflight

/// VM `start()` 前的 login keychain 狀態檢查。
///
/// macOS 15+ host 上 login keychain 未解鎖會讓 `start()` 以通用的
/// `VZErrorDomain` Code=1（internalError）失敗——真正的失敗發生在
/// com.apple.Virtualization.VirtualMachine helper 行程（SEP keypair 生成被
/// Security Server 拒絕），client 端錯誤的 userInfo 沒有任何線索。這裡用
/// `SecKeychainGetStatus` 做純狀態查詢：不彈窗、不解鎖、無副作用，讓呼叫端
/// 在碰 VZ 之前就拿到可修復的答案。
///
/// 為什麼用 deprecated（10.10）API：file keychain 的鎖定狀態沒有非 deprecated
/// 的查詢路徑——SecItem 體系無從表達「keychain 檔鎖著」，data protection
/// keychain 對無 entitlement 的 ad-hoc 簽章 binary 根本不可用（寫入直接回
/// errSecMissingEntitlement、查詢靜默回 not-found）。deprecation warning 以
/// protocol witness 慣用法壓掉（見 ``LegacyDefaultKeychainQuery``）。
///
/// 通過 ≠ `start()` 必成功——VZ 真正卡的是 SEP user keybag、keychain 鎖定
/// 狀態是高度相關的 proxy。這是「已知、可修復失敗模式的偵測器」；殘餘
/// case（root 執行、host 從未 GUI 登入過）由 `start()` 失敗後的二次診斷接住。
public enum KeychainPreflight {

	/// default keychain 的鎖定狀態。
	public enum Status: Equatable, Sendable {

		/// 已解鎖，`start()` 的 keychain 閘門應可通過。
		case unlocked

		/// 鎖定。修復：`security unlock-keychain <path>`。
		case locked(path: String?)

		/// 無 default keychain（headless / 從未 GUI 登入過的帳號），或
		/// default keychain 登記還在、檔案本體卻不存在。修復：
		/// `security create-keychain -p '' login.keychain`、unlock 後
		/// `security default-keychain -s login.keychain`（偵測對象是
		/// default keychain、修復也必須設回 default，光設 login-keychain
		/// 偏好不夠）。
		case missing

		/// 查詢本身回了非預期 OSStatus、無法判定。偵測器自己壞了不該
		/// 擋路——呼叫端不應拿這個 case 來擋 `start()`。
		case undetermined(status: OSStatus)
	}

	/// 查詢 default keychain 的鎖定狀態。純讀取：不觸發任何 UI、不解鎖、
	/// 不動 process-global 狀態。做成函式而非 computed property：每次呼叫
	/// 都經 IPC 問 securityd、值隨外界（解鎖 / 上鎖）即時變動，property
	/// 會誤導出「便宜且穩定」的預期。
	public static func status() -> Status {
		query.defaultKeychainStatus()
	}

	/// 唯一的查詢實作。經 existential 持有讓呼叫端走 protocol witness。
	private static let query: any DefaultKeychainQuerying = LegacyDefaultKeychainQuery()
}

// MARK: - DefaultKeychainQuerying

/// 查詢介面抽象。存在目的純粹是讓 ``KeychainPreflight`` 經 protocol witness
/// 呼叫 deprecated 實作而不觸發 deprecation 診斷。繼承 Sendable 讓
/// existential 可放進 static let（Swift 6 對 global 狀態的要求）。
private protocol DefaultKeychainQuerying: Sendable {

	/// 查 default keychain 的鎖定狀態。
	func defaultKeychainStatus() -> KeychainPreflight.Status
}

// MARK: - LegacyDefaultKeychainQuery

/// SecKeychain* 系 deprecated API 的唯一收容所。
///
/// 零 warning 靠兩層機制、缺一不可：呼叫端經 protocol witness 呼叫不觸發
/// deprecation 診斷；本型別成員自身標 deprecated、函式體成為 deprecated
/// context、內部呼叫同系 deprecated API 不再警告。此慣用法依賴現行編譯器
/// 診斷規則、非語言規格保證——若未來 swiftc 補上診斷，退路是收斂成單一
/// wrapper 函式標 deprecated、接受恰好一個 warning。
private struct LegacyDefaultKeychainQuery: DefaultKeychainQuerying {

	@available(macOS, deprecated: 10.10)
	func defaultKeychainStatus() -> KeychainPreflight.Status {
		var keychain: SecKeychain?
		// OSStatus 顯式標註不只為可讀性：SecKeychain* 函式大寫開頭、省略型別
		// 會被 formatter 的 propertyTypes 規則誤判為型別改寫成 .init(...)。
		let copyStatus: OSStatus = SecKeychainCopyDefault(&keychain)
		guard copyStatus != errSecNoDefaultKeychain else {
			return .missing
		}
		guard copyStatus == errSecSuccess else {
			return .undetermined(status: copyStatus)
		}
		guard let keychain else {
			// Copy 成功卻給 nil 違反 CF 慣例、理論上不可達；用 internal
			// component 當 sentinel，避免 undetermined 攜帶成功碼 0。
			return .undetermined(status: errSecInternalComponent)
		}
		var keychainStatus: SecKeychainStatus = .init()
		let statusResult: OSStatus = SecKeychainGetStatus(keychain, &keychainStatus)
		// 登記還在、檔案本體被刪：ref 建得出來、GetStatus 才報檔不存在——
		// 與「從未設定」同屬可修復的 missing、不是偵測器故障。
		guard statusResult != errSecNoSuchKeychain else {
			return .missing
		}
		guard statusResult == errSecSuccess else {
			return .undetermined(status: statusResult)
		}
		guard keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0 else {
			return .locked(path: path(of: keychain))
		}
		return .unlocked
	}

	/// 取 keychain 檔案路徑、供鎖定時組修復指令；取不到不影響判定（nil）。
	@available(macOS, deprecated: 10.10)
	private func path(of keychain: SecKeychain) -> String? {
		var buffer: [CChar] = .init(repeating: 0, count: Int(PATH_MAX))
		var length: UInt32 = .init(buffer.count)
		guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else {
			return nil
		}
		// length 出參 = 不含 NUL 的實際長度；用它截斷再以 failable 解碼（避開
		// String(cString: [CChar]) 這個 stdlib 已 deprecated 的 overload；非法
		// UTF-8 回 nil、由呼叫端當「取不到路徑」處理，best-effort 不影響判定）。
		return String(bytes: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), encoding: .utf8)
	}
}
