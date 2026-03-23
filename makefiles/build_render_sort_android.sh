#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_FILE="$ROOT_DIR/all/render_sort.c"
OUT_FILE="tmp/librender_sort_android.so"
ABI="${ABI:-arm64-v8a}"
API_LEVEL="${API_LEVEL:-21}"

if [ ! -f "$SRC_FILE" ]; then
    echo "ERROR: source file not found: $SRC_FILE" >&2
    exit 1
fi

if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME:-}" ]; then
    NDK_DIR="$ANDROID_NDK_HOME"
elif [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "${ANDROID_NDK_ROOT:-}" ]; then
    NDK_DIR="$ANDROID_NDK_ROOT"
elif [ -d "$HOME/Android/Sdk/ndk" ]; then
    latest_ndk="$(ls -1 "$HOME/Android/Sdk/ndk" | sort -V | tail -n 1)"
    NDK_DIR="$HOME/Android/Sdk/ndk/$latest_ndk"
else
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME or ANDROID_NDK_ROOT." >&2
    exit 1
fi

TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -d "$TOOLCHAIN" ]; then
    echo "ERROR: toolchain not found: $TOOLCHAIN" >&2
    exit 1
fi

case "$ABI" in
    arm64-v8a)
        TARGET_TRIPLE="aarch64-linux-android"
        ;;
    armeabi-v7a)
        TARGET_TRIPLE="armv7a-linux-androideabi"
        ;;
    x86_64)
        TARGET_TRIPLE="x86_64-linux-android"
        ;;
    *)
        echo "ERROR: unsupported ABI: $ABI" >&2
        exit 1
        ;;
esac

CC="$TOOLCHAIN/${TARGET_TRIPLE}${API_LEVEL}-clang"
if [ ! -x "$CC" ]; then
    echo "ERROR: compiler not found: $CC" >&2
    exit 1
fi

echo "Building Android render sort library..."
echo "NDK: $NDK_DIR"
echo "ABI: $ABI"
echo "API: $API_LEVEL"
echo "Output: $OUT_FILE"

"$CC" \
    -shared \
    -fPIC \
    -O3 \
    -Wall \
    -Wextra \
    -o "$OUT_FILE" \
    "$SRC_FILE"

echo "Built: $OUT_FILE"
