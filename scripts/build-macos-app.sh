#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DEFAULT_XCODE="/Volumes/Disk/Applications/Xcode.app/Contents/Developer"

if [[ -z "${DEVELOPER_DIR:-}" && -d "$DEFAULT_XCODE" ]]; then
    export DEVELOPER_DIR="$DEFAULT_XCODE"
fi

cd "$ROOT_DIR"
swift build -c debug --product ClassBridgeMac

BIN_DIR="$(swift build -c debug --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/LecCue.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/Resources/LecCue-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/ClassBridgeMac" "$MACOS_DIR/LecCue"
chmod +x "$MACOS_DIR/LecCue"

codesign --force --sign - --timestamp=none "$APP_DIR"
echo "$APP_DIR"
