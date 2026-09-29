# ZLMediaKit 构建与制品方案（building/）

> 本目录为「专用构建目录」，与上游源码解耦，避免 `git pull` 上游时配置被覆盖。
> 所有 GitHub Actions 工作流均为 **手动触发**（`workflow_dispatch`），版本号手动填写、**不加 `v` 前缀**。

---

## 一、组件分析

### 1. 组件清单与编译方式

| 组件 | 产物 | 来源目录 | 说明 |
| --- | --- | --- | --- |
| **mediaserver** | `MediaServer` 可执行文件 + `config.ini` + `www/` + `default.pem` | `server/`（主程序）、`src/`（核心库 `libzlmedia_kit`，静态链入，不单独发布）、`3rdpart/`（子模块 `ZLToolKit`/`jsoncpp`/`media-server`） | 主服务运行时，部署形态 |
| **mkapi** | `libmk_api.so` + 头文件（`api/include/*.h`、`mk_export.h`） | `api/` | C API SDK，供二次开发嵌入，作为库制品发布 |
| （可选）tests | `tests/` 下多个测试程序 | `tests/` | 开发/QA 用，本方案默认不打包 |

- **构建系统**：CMake（`cmake_minimum_required 3.1.3...3.26`）。
- **核心依赖链**：WebRTC 需要 `SRTP` + `OpenSSL`；SCTP/datachannel 可选需要 `usrsctp`（`find_package` 找不到时自动关闭，不报错）；`SRT` 由 ZLMediaKit 自带 `srt/` 源码编译，**无需外部依赖**。
- **官方原始编译**（参考）：在 CentOS7 容器内静态编 `openssl 1.1.1` + `usrsctp 0.9.5.0` + `libsrtp 2.3.0` + `cmake 3.29.5`；根 `dockerfile` 在 `ubuntu:24.04` 内编译，启用 `WEBRTC/FFMPEG/PYTHON`、关闭 `TESTS/API`。
- **子模块**：通过 `.gitmodules_github`（GitHub 镜像）替换 `.gitmodules`（gitee 镜像）拉取，规避 gitee 在 GitHub Runner 上的不稳定性。本方案在 workflow 中直接将子模块 URL 改写为 GitHub 镜像，不依赖 `.gitmodules_github` 是否存在。

### 2. 原容器打包方式

| 文件 | 做法 | 问题 |
| --- | --- | --- |
| 根 `dockerfile` | `ubuntu:24.04` 多阶段；build 阶段手动下载编译 `libsrtp 2.3.0`；runtime 阶段装 `libssl-dev/ffmpeg/python3` 等 | 在镜像内编译，体积大、依赖旧；FFMPEG 引入重依赖 |
| `build_docker_images.sh` | `docker buildx --platform linux/amd64\|linux/arm64`（**QEMU 模拟**，慢且易失败），tag `zlmediakit/zlmediakit:Release.<version>` | QEMU 模拟 arm64 编译极易超时/失败 |
| `.github/workflows/docker.yml` | push 到 `master/feature/*/release/*` 时多架构推 `docker.io`（QEMU 模拟） | 非手动触发；依赖 Docker Hub 凭据；QEMU 不稳 |

### 3. 原部署方案

- **Docker**：运行镜像，暴露 `1935/554/80/443/10000/8000/9000`（TCP+UDP）；用 ConfigMap 挂载 `/opt/media/conf/` 覆盖配置；替换 `default.pem` 自定义证书。
- **K8s**：`k8s_readme.md` **仅有文字建议，仓库内无任何 k8s manifest 或 compose 文件**（本方案从零补齐，见 `../deploy/`）。
- **制品**：二进制仅作为 Actions artifact 暂存，**没有 GitHub Release 制品**；本次方案补齐 Release 附件 + GHCR 镜像。

---

## 二、新方案（building/）

### 设计决策

| 项 | 决策 | 理由 |
| --- | --- | --- |
| 多架构 | GitHub 原生 `ubuntu-24.04`(amd64) + `ubuntu-24.04-arm`(arm64) **各自原生编译** | 替代上游 QEMU 模拟，快且稳；制品/镜像只含 amd64/arm64，杜绝 `unknown` 架构 |
| 制品命名 | `mediaserver-linux-<arch>-<version>.tar.gz`、`mkapi-linux-<arch>-<version>.tar.gz` | 架构与版本均显式，无 `unknown` |
| 版本号 | 手动填写、**不加 `v` 前缀**，最终版本即所填 | 满足要求 |
| 推送目标 | 二进制 → GitHub Release 附件；镜像 → `ghcr.io/zhuyifeiRuichuang/zlmediakit` | 使用提供的 GitHub Token 即可，无需 Docker Hub 凭据 |
| 基础镜像 | `debian:13-slim`（glibc，兼容性最佳，约 27MB） | 在兼容性范围内取最新稳定版、最精简 |
| 功能矩阵 | 启用 `API/WEBRTC/SRT/SCTP/HLS/MP4/RTPPROXY/SERVER`；关闭 `FFMPEG/PYTHON/TESTS/PLAYER/MYSQL` | 生产可用、依赖最干净；PLAYER 依赖 FFMPEG 故一并关闭 |
| 镜像装配 | **从预编译制品装配**（非镜像内编译） | 多架构干净、可复现、体积小 |
| 防覆盖 | 脚本放 `building/`、部署放 `deploy/`；workflow 文件加 `zlm-` 前缀，不与上游 `docker.yml`/`linux.yml` 同名冲突 | 规避 `git pull` 上游导致配置被覆盖 |
| 子模块 | workflow 内将子模块 URL 改写为 GitHub 镜像 | 规避 gitee 在 GitHub Runner 不稳，防止构建故障 |

### 目录结构

```
building/
├── build.sh              # 原生编译 + 双组件打包（amd64/arm64）
├── Dockerfile.runtime    # 运行时镜像（debian:13-slim，从制品装配）
└── README.md             # 本文件
.github/workflows/
├── zlm-build-artifacts.yml  # 手动触发：编译 + 打包 + 创建 GitHub Release
└── zlm-build-images.yml     # 手动触发：从 Release 制品构建多架构 GHCR 镜像
deploy/                   # 见 ../deploy/README.md
```

### 功能矩阵（编译开关）

| 开关 | 值 | 说明 |
| --- | --- | --- |
| ENABLE_API | ON | 产出 mkapi 组件 |
| ENABLE_WEBRTC | ON | 需 SRTP + OpenSSL（系统库） |
| ENABLE_SRT | ON | 自带 srt/ 源码，无外部依赖 |
| ENABLE_SCTP | ON | 可选 usrsctp；找不到则自动关闭 datachannel |
| ENABLE_HLS / MP4 / RTPPROXY / SERVER | ON | 核心功能 |
| ENABLE_FFMPEG / PLAYER / PYTHON / TESTS / MYSQL | OFF | 精简依赖；PLAYER 依赖 FFMPEG |

### 手动触发顺序

1. **先触发 `zlm-build-artifacts`**：填写 `version`（如 `1.0.0`），矩阵编译 amd64/arm64，产出 4 个 tarball 并创建 GitHub Release。
2. **再触发 `zlm-build-images`**：填写相同 `version`（与 Release 标签一致），从 Release 下载 mediaserver 双架构制品，构建并推送 `ghcr.io/zhuyifeiRuichuang/zlmediakit:<version>` 与 `:latest`（多架构）。

> 镜像工作流依赖第一步生成的 Release 已存在，请按顺序触发。

### 本地复用（可选）

```bash
# 在装有 cmake/gcc/libssl-dev/libsrtp2-dev 的 Linux 上
SRC=$(pwd) OUT=$(pwd)/output bash building/build.sh amd64 1.0.0
```
