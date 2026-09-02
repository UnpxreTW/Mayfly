//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// session 操作紀錄的落點：``SessionStore`` 每次 spawn／execute／status／destroy 結束（成功或
/// 擲錯）就同步呼叫一次。函式庫層不決定寫去哪——daemon 執行檔接 stderr、測試接記憶體陣列；
/// 傳 `nil` 即完全關閉（不讀時鐘、不配置物件）。在 ``SessionStore`` 這個 actor 內被呼叫、
/// 呼叫彼此已序列化，實作端不必再自行上鎖。
public typealias SessionLogSink = @Sendable (SessionLogEvent) -> Void
