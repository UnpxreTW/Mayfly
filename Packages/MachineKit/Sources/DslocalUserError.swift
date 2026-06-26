//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``DslocalUser`` 產生密碼雜湊時的失敗。兩個 case 理論上都不該發生（輸入皆為
/// 程式寫死的合法參數）——失敗代表系統密碼學服務異常，誠實往上拋而非吞掉。
public enum DslocalUserError: Error, Equatable {

	/// `SecRandomCopyBytes` 取密碼學亂數失敗。
	case randomGenerationFailed(status: Int32)

	/// `CCKeyDerivationPBKDF` 衍生金鑰失敗。
	case keyDerivationFailed(status: Int32)
}
