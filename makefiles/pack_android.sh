#!/usr/bin/env bash
set -euo pipefail
VERSION_FILE="./version.lua"
# 可通过 VERSION_FILE 环境变量指定版本文件（可选）
# VERSION_FILE=${VERSION_FILE:-}
if [ -n "${VERSION_FILE:-}" ] && [ -f "$VERSION_FILE" ]; then
    # 仅匹配行首的 `id = "..."`，避免匹配到 bundle_id
    current_id=$(awk -F'"' '/^[[:space:]]*id[[:space:]]*=/ {print $2; exit}' "$VERSION_FILE")
    current_id=${current_id:-$(date +%s)}
else
    current_id=$(date +%s)
fi

mkdir -p ".versions"
ARCHIVE_DIR=".versions/KingdomRushDove-Android-v${current_id}.zip"
LOVE_FILE="../Application/love-android/app/src/embed/assets/game.love"
LOVE_ANDROID="../Application/love-android"
OUTPUT_RAW="app/build/outputs/apk/embedNoRecord/release/app-embed-noRecord-release.apk"
OUTPUT_FINAL="app/build/outputs/apk/embedNoRecord/release/KingdomRushDove-Android-v${current_id}.apk"
LOVE_FINGERPRINT_FILE=".versions/.love_input_fingerprint"

# 依赖检查
if ! command -v zip >/dev/null 2>&1; then
    echo "ERROR: zip not found" >&2
    exit 1
fi

# 选择 ImageMagick 命令：优先 magick，再用 convert
if command -v magick >/dev/null 2>&1; then
    IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
    IM_CMD="convert"
else
    echo "ERROR: ImageMagick (magick/convert) not found" >&2
    exit 1
fi

# 并行任务数（可通过环境变量 JOBS 调整）
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

DDS_ASSETS_DIR="./_assets/kr1-desktop/images/fullhd"

# 增量缓存目录（加速 DDS -> PNG）
CACHE_DIR=".versions/.android_png_cache"
CACHE_KEY_FILE="$CACHE_DIR/.cache_key"
# 转换参数变化时更新该 key，可自动失效缓存
CACHE_KEY="resize=50%|strip=1|tool=$IM_CMD"

mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_KEY_FILE" ] || [ "$(cat "$CACHE_KEY_FILE" 2>/dev/null || true)" != "$CACHE_KEY" ]; then
    echo "Cache key changed, rebuilding image cache..."
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    printf "%s" "$CACHE_KEY" > "$CACHE_KEY_FILE"
fi

# .love 输入指纹（增量跳过打包）
calc_love_fingerprint() {
    {
        echo "cache_key=$CACHE_KEY"
        # .love 直接打包的源文件（排除项需与 zip 保持一致）
        find . \
            -path "./.git" -prune -o \
            -path "./.versions" -prune -o \
            -path "./tmp" -prune -o \
            -path "./aidoc" -prune -o \
            -path "./.plugins" -prune -o \
            -path "./mods/local" -prune -o \
            -type f ! -name "*.dds" ! -name "*.exe" \
            ! -name "client.log" ! -name "client" \
            ! -name "https.dll" ! -name "https.so" \
            ! -name "run.bat" ! -name "launch.bat" \
            ! -name "存档位置.lnk" ! -name "dlfmt" \
            ! -name ".dlfmt_cache.json" ! -name "update.lua" \
            ! -name ".gdb_history" \
            -print0 \
        | sort -z \
        | xargs -0 stat -c 'SRC|%n|%s|%Y'

        # dds 源文件（用于驱动 png 产物变化）
        find "$DDS_ASSETS_DIR" -type f -name "*.dds" -print0 2>/dev/null \
        | sort -z \
        | xargs -0 stat -c 'DDS|%n|%s|%Y' 2>/dev/null || true
    } | sha256sum | awk '{print $1}'
}

new_fingerprint="$(calc_love_fingerprint)"
old_fingerprint="$(cat "$LOVE_FINGERPRINT_FILE" 2>/dev/null || true)"

rebuild_love=1
if [ -f "$LOVE_FILE" ] && [ -n "$old_fingerprint" ] && [ "$new_fingerprint" = "$old_fingerprint" ]; then
    rebuild_love=0
    echo ".love inputs unchanged, skipping .love rebuild."
fi

# 收集待处理 DDS 列表（相对于工作目录）
mapfile -d '' dds_files < <(find "$DDS_ASSETS_DIR" -type f -name "*.dds" -print0 || printf '')

# 更可靠地计算数量
dds_count=${#dds_files[@]}

if [ "$rebuild_love" -eq 1 ]; then
    echo "Creating base archive (excluding PNGs) -> $ARCHIVE_DIR"
    # 先打包项目中除 png 和 .versions 的文件（避免把 archive 自己打进去）
    zip -r "$ARCHIVE_DIR" . -x "*.dds" -x ".versions/*" -x "tmp/*" -x "*.exe" -x ".git/*" -x "KingdomRushDoveUpdater" -x "client.log" -x "client" -x "https.dll" -x "https.so" -x "run.bat" -x "launch.bat" -x "存档位置.lnk" -x "dlfmt" -x ".dlfmt_cache.json" -x "update.lua" -x ".gdb_history" -x "aidoc/*" -x ".plugins/*" -x "mods/local/*" -q

    # 创建临时目录用于放置缩放后的 png，保留相对路径
    tempdir=$(mktemp -d)
    trap 'rm -rf "$tempdir"' EXIT

    if [ "$dds_count" -eq 0 ]; then
        echo "No DDS files found in $DDS_ASSETS_DIR."
    else
        echo "Processing $dds_count DDS files with $JOBS jobs (ImageMagick: $IM_CMD, incremental cache enabled)..."

        export IM_CMD tempdir CACHE_DIR

        # 并行增量处理 DDS -> PNG（缩小一半）
        # 命中缓存：直接拷贝缓存结果；未命中：转换后写入缓存并拷贝
        printf "%s\0" "${dds_files[@]}" | xargs -0 -P "$JOBS" -I {} bash -c '
            src="$1"
            rel="${src#./}"
            dest="$tempdir/${rel%.dds}.png"
            cache_png="$CACHE_DIR/${rel%.dds}.png"

            mkdir -p "$(dirname "$dest")"
            mkdir -p "$(dirname "$cache_png")"

            if [ -f "$cache_png" ] && [ "$cache_png" -nt "$src" ]; then
                cp -f "$cache_png" "$dest"
            else
                # 用 ImageMagick 转换并缩小一半，写入缓存
                "$IM_CMD" "$src" -resize 50% -strip "$cache_png"
                cp -f "$cache_png" "$dest"
            fi
        ' _ {}

        processed=$(find "$tempdir" -type f -name "*.png" 2>/dev/null | wc -l || echo 0)
        printf "[PNG] %d/%d processed.\n" "$processed" "$dds_count"
    fi

    # 把处理好的 PNG 按相对路径追加到已有 zip 中
    if [ -d "$tempdir" ] && [ "$(find "$tempdir" -type f | wc -l)" -gt 0 ]; then
        echo "Appending processed PNGs to archive..."
        pushd "$tempdir" >/dev/null
        zip -r "$OLDPWD/$ARCHIVE_DIR" . -q
        popd >/dev/null
    else
        echo "No processed PNGs to append."
    fi

    # 生成 .love 文件（复制以保留 zip 备份）
    cp -f "$ARCHIVE_DIR" "$LOVE_FILE"
    printf "%s" "$new_fingerprint" > "$LOVE_FINGERPRINT_FILE"
    echo "Packed -> $LOVE_FILE"
else
    echo "Reusing existing .love -> $LOVE_FILE"
fi

cd $LOVE_ANDROID

./gradlew assembleEmbedNoRecordRelease

mv "$OUTPUT_RAW" "$OUTPUT_FINAL"

# 如果传入了参数 quick，则使用内网 scp 传输
if [ "${1:-}" = "quick" ]; then
    scp -P 60001 "$OUTPUT_FINAL" dove@10.112.99.5:/srv/files/王国保卫战Dove版-安卓端/
else
    scp -P 60001 "$OUTPUT_FINAL" dove@krdovedownload6.crazyspotteddove.top:/srv/files/王国保卫战Dove版-安卓端/
fi
