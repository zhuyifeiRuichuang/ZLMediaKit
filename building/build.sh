#!/usr/bin/env bash
#
# ZLMediaKit 原生编译 + 制品打包脚本（由 GitHub Actions 调用，亦可在本机复用）
#
# 用法:
#   build.sh <amd64|arm64> <version>
#
# 环境变量（可选）:
#   SRC   源码根目录           默认: 当前目录
#   OUT   产出目录（tarball）  默认: $SRC/output
#   MODEL 编译类型             默认: Release
#
# 设计要点:
#   1. 原生编译（非交叉 / 非 QEMU），amd64 与 arm64 各在对应架构 runner 上编译，快且稳。
#   2. 显式传入 version，制品名严格为 mediaserver-linux-<arch>-<version>.tar.gz，
#      架构与版本均显式，绝不出现 unknown。
#   3. git 信息（commit/branch）由仓库本身提供，CMake 会写入真实版本，消除 Git_Unkown。
#   4. 功能矩阵「组件齐全」：在兼容性范围内启用全部生产可用组件，接受更大的制品/镜像体积。
#      - 编译在 ubuntu-24.04 runner 完成，二进制动态链接 ubuntu 的
#        libav*(FFMPEG) / libmysqlclient(MySQL) / libpython(Python) 等发行版库，
#        因此运行时镜像也必须使用 ubuntu:24.04（SONAME 一致），否则启动报
#        “error while loading shared libraries”。
#   5. 输出目录纠正：ZLMediaKit 的 CMake 把产物写到 <源码根>/release/linux/<Model>/，
#      而非 build/ 目录内。
#
set -euo pipefail

ARCH="${1:?用法: build.sh <amd64|arm64> <version>}"
VERSION="${2:?用法: build.sh <amd64|arm64> <version>}"
MODEL="${MODEL:-Release}"

SRC="${SRC:-$PWD}"
OUT="${OUT:-$SRC/output}"
BUILD="$SRC/build"

# ZLMediaKit 真实产物目录（注意：在源码根下，不在 build/ 内）
REL="$SRC/release/linux/$MODEL"

echo "==> [ZLMediaKit] 开始编译 arch=$ARCH version=$VERSION model=$MODEL"
echo "==> 源码根: $SRC"
echo "==> 产物目录: $REL"

cd "$SRC"

# ---- 配置（功能矩阵：组件齐全、生产可用，接受更大体积） ----
# 启用:
#   API          -> 产出 mkapi（C API SDK：libmk_api.so + 头文件）
#   WEBRTC       -> 需 SRTP + OpenSSL
#   SRT          -> 自带源码，静态链接（无需运行时 srt 库）
#   SCTP         -> datachannel（可选，缺失则自动关闭）
#   HLS / MP4 / RTPPROXY / SERVER
#   PLAYER       -> 依赖 FFMPEG（点播/播放）
#   FFMPEG       -> 媒体文件解封装/转码（动态链接发行版 libav*）
#   PYTHON       -> 内嵌 Python 解释器（pybind11::embed，需 python3-dev）
#   MYSQL        -> MySQL 客户端钩子（动态链接 libmysqlclient）
#   OPENSSL      -> HTTPS/RTSPS/WebRTC
# 关闭:
#   TESTS        -> 开发自测用，非运行时组件
cmake -S . -B "$BUILD" -DCMAKE_BUILD_TYPE="$MODEL" \
  -DENABLE_API=ON \
  -DENABLE_WEBRTC=ON \
  -DENABLE_SRT=ON \
  -DENABLE_SCTP=ON \
  -DENABLE_HLS=ON \
  -DENABLE_MP4=ON \
  -DENABLE_RTPPROXY=ON \
  -DENABLE_SERVER=ON \
  -DENABLE_PLAYER=ON \
  -DENABLE_FFMPEG=ON \
  -DENABLE_PYTHON=ON \
  -DENABLE_MYSQL=ON \
  -DENABLE_TESTS=OFF \
  -DENABLE_OPENSSL=ON

cmake --build "$BUILD" -j "$(nproc)"

if [ ! -x "$REL/MediaServer" ]; then
  echo "!! MediaServer 未生成，编译失败" >&2
  exit 1
fi
if [ ! -e "$REL/libmk_api.so" ]; then
  echo "!! libmk_api.so 未生成（ENABLE_API 应开启），编译失败" >&2
  exit 1
fi

mkdir -p "$OUT"

# ---- 组件 1: mediaserver（主服务运行时，组件齐全） ----
MS="$OUT/stage/mediaserver"
rm -rf "$MS"; mkdir -p "$MS/bin" "$MS/conf"
cp "$REL/MediaServer"        "$MS/bin/"
cp "$SRC/default.pem"        "$MS/bin/"
cp -r "$SRC/www"             "$MS/bin/www"
cp "$SRC/conf/config.ini"    "$MS/conf/"
# 可选调试符号（Release + objcopy 时生成）
[ -f "$REL/MediaServer.debug" ] && cp "$REL/MediaServer.debug" "$MS/bin/" || true
# 防御性：把产物目录中可能出现的其它共享库一并带入（如未来开启某动态组件）
for so in "$REL"/*.so*; do
  [ -e "$so" ] && cp -n "$so" "$MS/bin/" || true
done
tar -C "$MS" -czf "$OUT/mediaserver-linux-$ARCH-$VERSION.tar.gz" .

# ---- 组件 2: mkapi（C API SDK：库 + 头文件） ----
MK="$OUT/stage/mkapi"
rm -rf "$MK"; mkdir -p "$MK/lib" "$MK/include"
# 共享库（ENABLE_API_STATIC_LIB 默认 OFF -> libmk_api.so）
cp "$REL"/libmk_api.so*        "$MK/lib/" 2>/dev/null || true
# 公共头文件 + 生成的导出头
cp "$SRC"/api/include/*.h      "$MK/include/"
cp "$BUILD"/api/mk_export.h    "$MK/include/" 2>/dev/null || true
tar -C "$MK" -czf "$OUT/mkapi-linux-$ARCH-$VERSION.tar.gz" .

echo "==> 产出制品:"
ls -lh "$OUT"/*.tar.gz
echo "==> 完成 arch=$ARCH"
