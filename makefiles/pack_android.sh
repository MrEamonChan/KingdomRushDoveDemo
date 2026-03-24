#!/usr/bin/env bash
set -euo pipefail

# 优化选项：是否删除非必需文件以减小包体积

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

# 检查 astcenc 是否可用（用于高效的 ASTC 4x4 转换）
HAVE_ASTCENC=0
if command -v astcenc >/dev/null 2>&1; then
    HAVE_ASTCENC=1
fi

# 并行任务数（可通过环境变量 JOBS 调整）
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

DDS_ASSETS_DIR="./_assets/kr1-desktop/images/fullhd"

# 增量缓存目录（加速 DDS -> ASTC/PNG）
CACHE_DIR=".versions/.android_image_cache"
CACHE_KEY_FILE="$CACHE_DIR/.cache_key"
# 转换参数变化时更新该 key，可自动失效缓存
CACHE_KEY="resize=50%|strip=1|astc=$HAVE_ASTCENC|tool=$IM_CMD"

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
    # 生成 Android 专用渲染排序库，避免与 Linux 同名库混用
    # bash makefiles/build_render_sort_android.sh

    echo "Creating base archive (excluding PNGs) -> $ARCHIVE_DIR"

    # 先打包项目中除 dds 和 .versions 的文件（避免把 archive 自己打进去）
    zip -r "$ARCHIVE_DIR" . -x "*.dds" -x ".versions/*" -x "tmp/*" -x "*.exe" -x ".git/*" -x "KingdomRushDoveUpdater" -x "client.log" -x "client" -x "https.dll" -x "https.so" -x "run.bat" -x "launch.bat" -x "存档位置.lnk" -x "dlfmt" -x ".dlfmt_cache.json" -x "update.lua" -x ".gdb_history" -x "aidoc/*" -x ".plugins/*" -x "mods/local/*" -x "all/librender_sort.so" -x "all/librender_sort.dll" -x "love_env/*" -x ".vscode/*" -x "Makefile" -x "makefiles/*" -x "scripts/*" -x "dlfmt_task.json" -x "run.bat" -x "README.md" -x "launch.bat" -x "KingdomRushDove版启动器.exe" -x "current_version_commit_hash.txt" -x ".gitignore" -x "游玩必读说明，务必阅读.url" -q

    # 分析图像大小，生成缩放映射
    echo "Analyzing image sizes from Lua definitions..."
    RESIZE_MAP_FILE=".versions/.resize_map.txt"
    if ! lua makefiles/analyze_image_sizes.lua; then
        echo "WARNING: Failed to analyze image sizes, using heuristic method"
    fi

    # 创建临时目录用于放置缩放后的 png，保留相对路径
    tempdir=$(mktemp -d)
    trap 'rm -rf "$tempdir"' EXIT

    if [ "$dds_count" -eq 0 ]; then
        echo "No DDS files found in $DDS_ASSETS_DIR."
    else
        echo "Processing $dds_count DDS files with $JOBS jobs (ASTC support: $HAVE_ASTCENC, incremental cache enabled)..."

        export IM_CMD tempdir CACHE_DIR HAVE_ASTCENC RESIZE_MAP_FILE

        # 并行增量处理 DDS -> ASTC（或 PNG 如果 ASTC 不可用）
        # 命中缓存：直接拷贝缓存结果；未命中：转换后写入缓存并拷贝
        printf "%s\0" "${dds_files[@]}" | xargs -0 -P "$JOBS" -I {} bash -c '
            should_resize() {
                local filename="$1"
                if [ ! -f "$RESIZE_MAP_FILE" ]; then
                    # 回退启发式方法
                    case "$filename" in
                        gui_*|loading_*|achievements_*|skills_*) return 1 ;;
                        kr[0-9]_*) return 1 ;;
                        *) return 0 ;;
                    esac
                fi

                # 从 resize_map 读取
                local result=$(grep "^${filename}.dds=" "$RESIZE_MAP_FILE" 2>/dev/null | cut -d= -f2)
                [ "$result" = "1" ]
            }

            src="$1"
            rel="${src#./}"
            base_name="${rel%.dds}"

            # 决定输出格式：优先 ASTC 4x4，其次 PNG
            if [ "$HAVE_ASTCENC" -eq 1 ]; then
                output_ext="astc"
                cache_file="$CACHE_DIR/${base_name}.astc"
            else
                output_ext="png"
                cache_file="$CACHE_DIR/${base_name}.png"
            fi

            dest="$tempdir/${base_name}.${output_ext}"

            mkdir -p "$(dirname "$dest")"
            mkdir -p "$(dirname "$cache_file")"

            if [ -f "$cache_file" ] && [ "$cache_file" -nt "$src" ]; then
                cp -f "$cache_file" "$dest"
            else
                # 先用 ImageMagick 转为 PNG，再转 ASTC（或直接用 PNG）
                if [ "$output_ext" = "astc" ]; then
                    # DDS -> PNG（临时中间格式）-> ASTC 6x6 sRGB
                    temp_png="/tmp/temp_${RANDOM}.png"

                    # 根据 resize_map 判断是否缩放
                    if should_resize "$base_name"; then
                        "$IM_CMD" "$src" -resize 50% -strip "png:$temp_png" 2>/dev/null
                    else
                        "$IM_CMD" "$src" -strip "png:$temp_png" 2>/dev/null
                    fi

                    # astcenc -cs <input.png> <output.astc> <blocksize> <quality>
                    # -cs: sRGB LDR 压缩, 6x6: 块大小, -fast: 快速压缩质量, -silent: 无日志
                    if astcenc -cs "$temp_png" "$cache_file" 6x6 -fast -silent 2>/dev/null; then
                        # ASTC 转换成功
                        rm -f "$temp_png"
                    else
                        # 如果 astcenc 失败，降级到 PNG
                        cache_png="${cache_file%.astc}.png"
                        mv "$temp_png" "$cache_png"
                        dest="${dest%.astc}.png"
                        cache_file="$cache_png"
                    fi
                else
                    # DDS -> PNG
                    if should_resize "$base_name"; then
                        "$IM_CMD" "$src" -resize 50% -strip "$cache_file"
                    else
                        "$IM_CMD" "$src" -strip "$cache_file"
                    fi
                fi
                cp -f "$cache_file" "$dest"
            fi
        ' _ {}

        # 处理 PNG 文件（直接转 ASTC，不缩放）
        if [ "$HAVE_ASTCENC" -eq 1 ]; then
            png_files_count=$(find "$DDS_ASSETS_DIR" -type f -name "*.png" 2>/dev/null | wc -l || echo 0)
            if [ "$png_files_count" -gt 0 ]; then
                echo "Processing $png_files_count PNG files for ASTC conversion..."
                find "$DDS_ASSETS_DIR" -type f -name "*.png" -print0 | xargs -0 -P "$JOBS" -I {} bash -c '
                    src="$1"
                    rel="${src#./}"
                    base_name="${rel%.png}"

                    cache_file="$CACHE_DIR/${base_name}.astc"
                    dest="$tempdir/${base_name}.astc"

                    mkdir -p "$(dirname "$dest")"
                    mkdir -p "$(dirname "$cache_file")"

                    if [ -f "$cache_file" ] && [ "$cache_file" -nt "$src" ]; then
                        cp -f "$cache_file" "$dest"
                    else
                        # PNG 直接转 ASTC，不缩放
                        if astcenc -cs "$src" "$cache_file" 6x6 -fast -silent 2>/dev/null; then
                            cp -f "$cache_file" "$dest"
                        else
                            # 失败则保留 PNG
                            cp -f "$src" "$tempdir/${base_name}.png"
                        fi
                    fi
                ' _ {}
            fi
        fi

        processed=$(find "$tempdir" -type f \( -name "*.astc" -o -name "*.png" \) 2>/dev/null | wc -l || echo 0)
        astc_count=$(find "$tempdir" -type f -name "*.astc" 2>/dev/null | wc -l || echo 0)
        printf "[IMAGE] %d/%d processed (ASTC: %d, PNG: %d).\n" "$processed" "$dds_count" "$astc_count" "$((processed - astc_count))"
    fi

    # 把处理好的图片（ASTC/PNG）按相对路径追加到已有 zip 中
    if [ -d "$tempdir" ] && [ "$(find "$tempdir" -type f | wc -l)" -gt 0 ]; then
        echo "Appending processed images to archive..."
        pushd "$tempdir" >/dev/null
        zip -r "$OLDPWD/$ARCHIVE_DIR" . -q
        popd >/dev/null
    else
        echo "No processed images to append."
    fi

    # 压缩字体文件
    echo "Minifying fonts for Android..."
    if bash makefiles/minify_font.sh; then
        echo "Replacing fonts in archive with minified versions..."
        # 在临时目录中创建正确的目录结构
        mkdir -p "$ARCHIVE_DIR.tmp/_assets/all-desktop/fonts"
        cp tmp/msyh_minify.ttc "$ARCHIVE_DIR.tmp/_assets/all-desktop/fonts/msyh.ttc"
        cp tmp/msyhbd_minify.ttc "$ARCHIVE_DIR.tmp/_assets/all-desktop/fonts/msyhbd.ttc"
        
        # 从 zip 中删除原始字体文件
        zip -d "$ARCHIVE_DIR" "_assets/all-desktop/fonts/msyh.ttc" -q 2>/dev/null || true
        zip -d "$ARCHIVE_DIR" "_assets/all-desktop/fonts/msyhbd.ttc" -q 2>/dev/null || true
        
        # 添加新的字体文件到正确的位置
        (cd "$ARCHIVE_DIR.tmp" && zip -r "$OLDPWD/$ARCHIVE_DIR" _assets/all-desktop/fonts -q)
        rm -rf "$ARCHIVE_DIR.tmp"
    else
        echo "WARNING: Font minification failed, using original fonts"
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

if [ "${1:-}" = "no-upload" ]; then
    echo "Build complete, skipping upload as per argument."
    exit 0
fi

# 如果传入了参数 quick，则使用内网 scp 传输
if [ "${1:-}" = "quick" ]; then
    scp -P 60001 "$OUTPUT_FINAL" dove@10.112.99.5:/srv/files/王国保卫战Dove版-安卓端/
else
    scp -P 60001 "$OUTPUT_FINAL" dove@krdovedownload6.crazyspotteddove.top:/srv/files/王国保卫战Dove版-安卓端/
fi