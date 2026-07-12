#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SYSTEM_XCODE="/Applications/Xcode.app/Contents/Developer"
EXTERNAL_XCODE="/Volumes/Disk/Applications/Xcode.app/Contents/Developer"
CACHE_DIR="$ROOT_DIR/.build/mlx-metal"
METALLIB_PATH="$CACHE_DIR/mlx.metallib"
DERIVED_DATA="$ROOT_DIR/.build/mlx-derived-data"
MLX_PROJECT="$ROOT_DIR/.build/checkouts/mlx-swift/xcode/MLX.xcodeproj"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in "$SYSTEM_XCODE" "$EXTERNAL_XCODE"; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

if [[ ! -f "$METALLIB_PATH" ]]; then
    if [[ ! -d "$MLX_PROJECT" ]]; then
        print -u2 "MLX Swift is not resolved. Run swift package resolve first."
        exit 1
    fi

    mkdir -p "$CACHE_DIR"
    xcodebuild \
        -quiet \
        -project "$MLX_PROJECT" \
        -scheme MLX \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA" \
        build >&2

    GENERATED_METALLIB="$DERIVED_DATA/Build/Products/Debug/Cmlx.framework/Versions/A/Resources/default.metallib"
    if [[ ! -f "$GENERATED_METALLIB" ]]; then
        print -u2 "MLX Metal library was not generated."
        exit 1
    fi
    cp "$GENERATED_METALLIB" "$METALLIB_PATH"
fi

print "$METALLIB_PATH"
