# Mayfly

全 Swift、Apple Silicon、**ephemeral-first** 的 macOS / Linux VM 工具，建在 Apple Virtualization.framework 上。

> ⚠️ 狀態：Early WIP — 早期開發階段，暫不建議使用。

## 需求

macOS 26+（Apple Silicon）、Xcode 26+、Tuist 4。

## 開發

專案分三個 SwiftPM package（`Packages/MachineKit`、`Packages/mayfly-cli`、`Packages/LinuxNodeKit`），各自建置與測試：

```shell
swift build --package-path Packages/MachineKit
swift build --package-path Packages/mayfly-cli
swift build --package-path Packages/LinuxNodeKit
swift test --package-path Packages/MachineKit
swift test --package-path Packages/mayfly-cli
swift test --package-path Packages/LinuxNodeKit
```

CI（GitHub Actions）跑上述指令，見 `.github/workflows/build.yml` 與 `test.yml`。