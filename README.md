# Mayfly

全 Swift、Apple Silicon、**ephemeral-first** 的 macOS / Linux VM 工具，建在 Apple Virtualization.framework 上。

> ⚠️ 狀態：Early WIP — 早期開發階段，暫不建議使用。

## 需求

macOS 26+（Apple Silicon）、Xcode 26+。建置 app 另需 Tuist，版本釘在 `.config/mise.toml`。

## 開發

引擎、CLI 與畫面層都在 SwiftPM package 裡，各自建置與測試：

```shell
swift build --package-path Packages/MachineKit
swift build --package-path Packages/mayfly-cli
swift build --package-path Packages/LinuxNodeKit
swift build --package-path Packages/MayflyUI
swift test --package-path Packages/MachineKit
swift test --package-path Packages/mayfly-cli
swift test --package-path Packages/LinuxNodeKit
swift test --package-path Packages/MayflyUI
```

CI（GitHub Actions）跑上述指令，見 `.github/workflows/build.yml` 與 `test.yml`。

### 執行檔簽章

`mayfly` 要真的開起 guest 需要 `com.apple.security.virtualization`，而 SwiftPM 不簽 entitlement——**每一次重建都會把執行檔洗回沒有 entitlement 的 ad-hoc 簽章**，而且要等到開機器時才失敗。要在本機實跑時，用把建置與補簽綁在一起的腳本：

```shell
bash Scripts/build-signed-cli.sh
```

腳本建置 release 版後依 `Mayfly.entitlements` 重簽，並回讀確認 entitlement 真的在（讀不到就回非零）。單純跑 `swift build` 出來的執行檔沒有這一項，開 guest 會被擋下。

### app

app 需要真正的 `.app` bundle 才簽得上 `com.apple.security.virtualization`，SwiftPM 產不出來，故 app target 由 Tuist 產生（版本釘在 `.config/mise.toml`）：

```shell
tuist generate --no-open
xcodebuild -workspace Mayfly.xcworkspace -scheme Mayfly -configuration Debug -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` 是非互動建置的必要旗標——package 的建置外掛在互動 Xcode 裡要人工信任，命令列不加會直接失敗。產物走 ad-hoc 簽章，不需開發者憑證。

只有 app target 進 Tuist；`mayfly` 執行檔維持純 SwiftPM。畫面程式碼放 `Packages/MayflyUI`（吃得到 lint 與單元測試），Xcode target 側只留 `Sources/MayflyApp.swift` 一個進入點。

app 的最低系統版本與四個 package 同為 macOS 26——全專案單一下限，沒有分層。

**本節的兩條指令不在 CI 覆蓋範圍**（CI 只跑上一節的 `swift build` / `swift test`）：改動 `Project.swift`、`Mayfly.entitlements` 或 `Sources/MayflyApp.swift` 後，送出前請在本機跑過 generate ＋ build。
