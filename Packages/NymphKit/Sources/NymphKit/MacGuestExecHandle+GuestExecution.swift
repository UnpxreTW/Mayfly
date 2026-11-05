//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import MachineKit

// MARK: - MacGuestExecHandle + GuestExecution

/// 真機的命令執行即 ``GuestExecution``：`wait(timeout:)` 與 `cancel()` 的語義原樣沿用。
extension MacGuestExecHandle: GuestExecution {}
