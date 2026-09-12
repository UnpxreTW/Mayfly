# SPDX-FileCopyrightText: 2026 Unpxre (GitHub: UnpxreTW)
# SPDX-License-Identifier: Apache-2.0

# 只做靜態檢查的 Linux 執行環境：帶 SwiftLint 與 SwiftFormat 的 arm64 執行檔、
# 不帶 Swift toolchain。lint job 用這顆，pull 時不必背整套工具鏈。

FROM debian:bookworm-slim AS tools

ARG SWIFTLINT_VERSION=0.65.1
ARG SWIFTLINT_SHA256=9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8
ARG SWIFTFORMAT_VERSION=0.63.0
ARG SWIFTFORMAT_SHA256=b0335af32e2c5944a17b3e6d916ff4552eb757ed88f68b80fd19415824850717

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl unzip \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/tools

# 兩支都先對 sha256：release 資產是可被重新上傳的，只釘版本號釘不住內容。
RUN curl -fsSL -o swiftlint.zip "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_arm64.zip" \
	&& echo "${SWIFTLINT_SHA256}  swiftlint.zip" | sha256sum -c - \
	&& unzip -q swiftlint.zip swiftlint-static \
	&& install -D -m 0755 swiftlint-static /out/swiftlint

RUN curl -fsSL -o swiftformat.zip "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux_aarch64.zip" \
	&& echo "${SWIFTFORMAT_SHA256}  swiftformat.zip" | sha256sum -c - \
	&& unzip -q swiftformat.zip \
	&& install -D -m 0755 swiftformat_linux_aarch64 /out/swiftformat

FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends bash ca-certificates curl git jq tzdata \
	&& rm -rf /var/lib/apt/lists/*

# 取的是 zip 裡的 swiftlint-static：完全靜態連結，這顆 image 因此不必補 Swift runtime；
# 同一個 zip 內的 swiftlint 動態版還要 libcurl4 與 libxml2。
COPY --from=tools /out/swiftlint /usr/local/bin/swiftlint
COPY --from=tools /out/swiftformat /usr/local/bin/swiftformat

ENV HOME=/root
WORKDIR /root
CMD ["/bin/bash"]
