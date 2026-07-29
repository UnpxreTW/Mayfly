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

### app

app 需要真正的 `.app` bundle 才簽得上 `com.apple.security.virtualization`，SwiftPM 產不出來，故 app target 由 Tuist 產生（版本釘在 `.config/mise.toml`）：

```shell
tuist generate --no-open
xcodebuild -workspace Mayfly.xcworkspace -scheme Mayfly -configuration Debug -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` 是非互動建置的必要旗標——package 的建置外掛在互動 Xcode 裡要人工信任，命令列不加會直接失敗。產物走 ad-hoc 簽章，不需開發者憑證。

只有 app target 進 Tuist；`mayfly` 執行檔維持純 SwiftPM。畫面程式碼放 `Packages/MayflyUI`（吃得到 lint 與單元測試），Xcode target 側只留 `Sources/MayflyApp.swift` 一個進入點。

app 的最低系統版本是 macOS 15，高於引擎與 CLI——外殼用得上新 API，底層元件保留較低下限。

**本節的兩條指令不在 CI 覆蓋範圍**（CI 只跑上一節的 `swift build` / `swift test`）：改動 `Project.swift`、`Mayfly.entitlements` 或 `Sources/MayflyApp.swift` 後，送出前請在本機跑過 generate ＋ build。
