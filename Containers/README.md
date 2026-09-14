# Linux 容器映像

`mayfly spawn --os linux` 起的是容器，容器裡有什麼由映像決定。這個目錄放的是給 CI job 用的兩顆映像的定義與建置流程。

內建別名 `alpine` 只夠冒煙：它沒有 `/bin/bash`，跑不了 job runner 的步驟腳本。

## 兩顆映像

| 目錄 | 用途 | 內容 |
|---|---|---|
| `ci-lint` | 只做靜態檢查的 job | Debian bookworm-slim ＋ git／curl／jq ＋ SwiftLint、SwiftFormat 的 arm64 執行檔（無 Swift toolchain） |
| `ci-swift` | 在 Linux 上 `swift build` / `swift test` 的 job | 官方 `swift:6.3.3-bookworm` ＋ git／curl／jq |

分成兩顆是因為兩種 job 的體積差一個量級：只跑 lint 的 job 不必為了工具鏈多拉幾 GB。

## 映像要滿足的條件

執行環境是容器，起來之後 job runner 會直接在裡面跑指令，所以下列每一項都是硬需求：

- `/bin/bash`（步驟腳本以登入 shell `-l` 執行）與 `/bin/sh`
- `base64`、`mkdir`、`dirname`、`chmod`、`umask`（注入檔的解碼與落檔）
- `git` 與 `ca-certificates`（取碼走 `git init` / `fetch` / `checkout`，倉庫 URL 是 HTTPS）
- `/tmp` 可寫（工作根在 `/tmp` 下）
- `/bin/true`、`/bin/sleep`（就緒探測與保活）
- `HOME` 有值（`bash -l` 與 git 都會讀）
- `linux/arm64`、執行身分 root

這幾項在 `.github/workflows/containers.yml` 的冒煙步驟裡逐條驗，改 Dockerfile 時不必自己記。

## 建置與發佈

建置與推送都由 `Container images` workflow 做，跑在 arm64 runner 上：

- **pull request**：只建置與冒煙，不推。
- **main** 或 **手動觸發**（`workflow_dispatch`）：建置、冒煙，然後推上 `ghcr.io/unpxretw/mayfly-ci-lint` 與 `ghcr.io/unpxretw/mayfly-ci-swift`，標 `latest` 與該次 commit 的 SHA。

推完那一次的 job summary 會印出 digest 形的完整參照：

```
ghcr.io/unpxretw/mayfly-ci-lint@sha256:...
```

部署時要引用的是這個 digest，不是 `latest`——`latest` 會被下一次推蓋掉，同一組設定在不同時間點會拉到不同的東西。

本機要單獨建一顆時（需要能建 `linux/arm64` 的 container runtime）：

```shell
docker build --platform linux/arm64 -t mayfly-ci-lint Containers/ci-lint
```

## 更新工具版本

SwiftLint 與 SwiftFormat 的版本與 sha256 釘在 `Containers/ci-lint/Dockerfile` 的 `ARG` 裡。要升版就改那四行：版本號自己填，checksum 取下載回來的 zip 自己算（release 沒有附 checksum 檔）。

```shell
curl -fsSL -o /tmp/swiftlint.zip https://github.com/realm/SwiftLint/releases/download/<版本>/swiftlint_linux_arm64.zip
shasum -a 256 /tmp/swiftlint.zip
```

只釘版本號釘不住內容——release 資產可以被重新上傳，所以 checksum 是必要的，不是裝飾。

Swift toolchain 版本在 `Containers/ci-swift/Dockerfile` 的 `FROM` 那行，跟著 macOS guest 的版本走：兩邊不同版時，同一份 package 在兩軌的結果差異會分不清是平台差異還是版本差異。
