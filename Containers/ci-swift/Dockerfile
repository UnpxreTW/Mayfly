# SPDX-FileCopyrightText: 2026 Unpxre (GitHub: UnpxreTW)
# SPDX-License-Identifier: Apache-2.0

# 帶 Swift toolchain 的 Linux 執行環境：供在 Linux 上跑 swift build / swift test 的 job 用。
# 版本跟著 macOS guest 的 toolchain 走（Swift 6.3.3），兩軌對同一份 package 才比得出差異。

FROM swift:6.3.3-bookworm

# 官方 image 已帶 git 與 curl，這裡仍顯式列出：job 需要哪些工具是這份 Dockerfile 的契約，
# 不是上游 image 的實作細節。
RUN apt-get update \
	&& apt-get install -y --no-install-recommends bash ca-certificates curl git jq tzdata \
	&& rm -rf /var/lib/apt/lists/*

ENV HOME=/root
WORKDIR /root
CMD ["/bin/bash"]
