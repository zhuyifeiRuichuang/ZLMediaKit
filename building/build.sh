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
#
set -euo pipefail

ARCH="${1:?用法: build.sh <amd64|arm64> <version>}"
VERSION="${2:?用法: build.sh <amd64|arm64> <version>}"
MODEL="${MODEL:-Release}"

SRC="${SRC:-$PWD}"
OUT="${OUT:-$SRC/output}"
BUILD="$SRC/build"

echo "==> [ZLMediaKit] 开始编译 arch=$ARCH version=$VERSION model=$MODEL"

cd "$SRC"

# ---- 配置（功能矩阵：生产可用、依赖最干净、不含 FFMPEG） ----
# 启用: API(产出 mkapi) / WEBRTC(需 SRTP+OpenSSL) / SRT / SCTP(datachannel, 可选) /
#       HLS / MP4 / RTPPROXY / SERVER
# 关闭: FFMPEG(Python 插件随之无意义) / TESTS / PLAYER(依赖 FFMPEG) / MYSQL
cmake -S . -B "$BUILD" -DCMAKE_BUILD_TYPE="$MODEL" \
  -DENABLE_API=ON \
  -DENABLE_WEBRTC=ON \
  -DENABLE_SRT=ON \
  -DENABLE_SCTP=ON \
  -DENABLE_HLS=ON \
  -DENABLE_MP4=ON \
  -DENABLE_RTPPROXY=ON \
  -DENABLE_SERVER=ON \
  -DENABLE_PLAYER=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_FFMPEG=OFF \
  -DENABLE_PYTHON=OFF \
  -DENABLE_MYSQL=OFF \
  -DENABLE_OPENSSL=ON

cmake --build "$BUILD" -j "$(nproc)"

REL="$BUILD/release/linux/$MODEL"
if [ ! -x "$REL/MediaServer" ]; then
  echo "!! MediaServer 未生成，编译失败" >&2
  exit 1
fi

mkdir -p "$OUT"

# ---- 组件 1: mediaserver（主服务运行时） ----
MS="$OUT/stage/mediaserver"
rm -rf "$MS"; mkdir -p "$MS/bin" "$MS/conf"
cp "$REL/MediaServer"        "$MS/bin/"
cp "$SRC/default.pem"        "$MS/bin/"
cp -r "$SRC/www"             "$MS/bin/www"
cp "$SRC/conf/config.ini"    "$MS/conf/"
[ -f "$REL/MediaServer.debug" ] && cp "$REL/MediaServer.debug" "$MS/bin/" || true
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
