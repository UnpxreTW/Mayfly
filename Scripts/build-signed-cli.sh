#!/bin/bash
# SPDX-FileCopyrightText: 2026 Unpxre (GitHub: UnpxreTW)
# SPDX-License-Identifier: Apache-2.0
#
# 建置 release 版的 mayfly 執行檔，並補上 Mayfly.entitlements 裡的
# com.apple.security.virtualization。
#
# SwiftPM 不簽 entitlement，而開 guest 需要這一項；因此每一次重建都會把執行檔洗回沒有
# entitlement 的 ad-hoc 簽章，而且要等到真的開機器時才失敗。建置與補簽綁在同一支腳本裡跑，
# 就不會留下「已重建、未重簽」的中間狀態。
#
# 用法：bash Scripts/build-signed-cli.sh

set -euo pipefail

readonly entitlement_key="com.apple.security.virtualization"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly package_path="$repo_root/Packages/mayfly-cli"
readonly entitlements="$repo_root/Mayfly.entitlements"

swift build -c release --package-path "$package_path"

binary="$(swift build -c release --package-path "$package_path" --show-bin-path)/mayfly"
if [ ! -x "$binary" ]; then
	echo "建置完成但找不到可執行的 $binary" >&2
	exit 1
fi

codesign --force --sign - --entitlements "$entitlements" "$binary"

# 回讀驗證：對沒有任何 entitlement 的執行檔，codesign -d 一樣回 exit 0、只是輸出空的，
# 所以判準只能是鍵名有沒有出現，不能看 exit code。
if ! codesign -d --entitlements - --xml "$binary" 2>/dev/null | grep -q "$entitlement_key"; then
	echo "重簽後回讀不到 ${entitlement_key}，請檢查 $entitlements 內容" >&2
	exit 1
fi

echo "已簽署並驗證：$binary"
