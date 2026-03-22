#!/bin/bash
# 处理单个图像文件的脚本

src="$1"
rel="$2"
base_name="$3"
output_ext="$4"
cache_file="$5"
dest="$6"
IM_CMD="$7"
HAVE_ASTCENC="$8"
RESIZE_MAP_FILE="$9"
CACHE_DIR="${10}"

mkdir -p "$(dirname "$dest")"
mkdir -p "$(dirname "$cache_file")"

# 从纯文本映射中查询是否需要缩放
should_resize() {
    local filename="$1"
    if [ ! -f "$RESIZE_MAP_FILE" ]; then
        # 回退到启发式方法
        case "$filename" in
            gui_*|loading_*|achievements_*|skills_*) return 1 ;;
            kr[0-9]_*) return 1 ;;
            *) return 0 ;;
        esac
    fi
    
    # 从纯文本中查询（格式：filename=1 或 filename=0）
    local result=$(grep "^${filename}=" "$RESIZE_MAP_FILE" 2>/dev/null | cut -d'=' -f2)
    
    if [ "$result" = "1" ]; then
        return 0  # 需要缩放
    else
        return 1  # 不需要缩放
    fi
}

if [ -f "$cache_file" ] && [ "$cache_file" -nt "$src" ]; then
    cp -f "$cache_file" "$dest"
else
    filename=$(basename "$base_name").dds
    
    if [ "$output_ext" = "astc" ]; then
        # DDS -> PNG -> ASTC
        temp_png="/tmp/temp_${RANDOM}.png"
        
        if should_resize "$filename"; then
            "$IM_CMD" "$src" -resize 50% -strip "png:$temp_png" 2>/dev/null
        else
            "$IM_CMD" "$src" -strip "png:$temp_png" 2>/dev/null
        fi
        
        if astcenc -cs "$temp_png" "$cache_file" 6x6 -fast -silent 2>/dev/null; then
            rm -f "$temp_png"
        else
            # 降级到 PNG
            cache_png="${cache_file%.astc}.png"
            mv "$temp_png" "$cache_png"
            dest="${dest%.astc}.png"
            cache_file="$cache_png"
        fi
    else
        # DDS -> PNG
        if should_resize "$filename"; then
            "$IM_CMD" "$src" -resize 50% -strip "$cache_file"
        else
            "$IM_CMD" "$src" -strip "$cache_file"
        fi
    fi
    
    cp -f "$cache_file" "$dest"
fi
