#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SYSTEM_XCODE="/Applications/Xcode.app/Contents/Developer"
EXTERNAL_XCODE="/Volumes/Disk/Applications/Xcode.app/Contents/Developer"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in "$SYSTEM_XCODE" "$EXTERNAL_XCODE"; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

cd "$ROOT_DIR"
swift build --disable-sandbox -c debug --product LingoSlateMac

BIN_DIR="$(swift build --disable-sandbox -c debug --show-bin-path)"
MLX_METALLIB="$("$ROOT_DIR/scripts/build-mlx-metallib.sh")"
APP_ICON="$("$ROOT_DIR/scripts/build-app-icon.sh")"
APP_DIR="$ROOT_DIR/.build/LingoSlate.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/Resources/LingoSlate-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/LingoSlateMac" "$MACOS_DIR/LingoSlate"
cp "$MLX_METALLIB" "$MACOS_DIR/mlx.metallib"
cp "$APP_ICON" "$RESOURCES_DIR/LingoSlate.icns"
chmod +x "$MACOS_DIR/LingoSlate"

codesign --force --deep --sign - --timestamp=none "$APP_DIR"
echo "$APP_DIR"
