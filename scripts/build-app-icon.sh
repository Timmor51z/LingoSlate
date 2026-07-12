#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_ICON="$ROOT_DIR/Resources/LingoSlate-AppIcon.png"
ICON_WORK_DIR="$ROOT_DIR/.build/LingoSlateIcon"
OUTPUT_ICON="$ROOT_DIR/.build/LingoSlate.icns"

mkdir -p "$ICON_WORK_DIR"

resize_icon() {
    local size="$1"
    sips -s format tiff -z "$size" "$size" "$SOURCE_ICON" \
        --out "$ICON_WORK_DIR/icon_$size.tiff" >/dev/null
}

for size in 16 32 48 128 256 512 1024; do
    resize_icon "$size"
done

tiffutil -catnosizecheck \
    "$ICON_WORK_DIR/icon_16.tiff" \
    "$ICON_WORK_DIR/icon_32.tiff" \
    "$ICON_WORK_DIR/icon_48.tiff" \
    "$ICON_WORK_DIR/icon_128.tiff" \
    "$ICON_WORK_DIR/icon_256.tiff" \
    "$ICON_WORK_DIR/icon_512.tiff" \
    "$ICON_WORK_DIR/icon_1024.tiff" \
    -out "$ICON_WORK_DIR/LingoSlate.tiff" >/dev/null
tiff2icns "$ICON_WORK_DIR/LingoSlate.tiff" "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
