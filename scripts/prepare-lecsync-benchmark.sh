#!/bin/zsh

set -euo pipefail
umask 077

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <LecSync-session-detail-json>" >&2
    exit 64
fi

ROOT_DIR="${0:A:h:h}"
SOURCE_JSON="$1"

if [[ ! -f "$SOURCE_JSON" ]]; then
    echo "LecSync cache file not found: $SOURCE_JSON" >&2
    exit 66
fi

for command_name in jq curl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 69
    fi
done

jq -e '
    (.id | type == "string") and
    (.audioUrl | type == "string") and
    (.segments | type == "array") and
    (.segments | length > 0)
' "$SOURCE_JSON" >/dev/null

SESSION_ID="$(jq -er '.id' "$SOURCE_JSON")"
if [[ ! "$SESSION_ID" =~ '^[A-Za-z0-9_-]+$' ]]; then
    echo "Unsafe LecSync session id" >&2
    exit 65
fi

OUTPUT_DIR="$ROOT_DIR/Benchmarks/Private/$SESSION_ID"
REFERENCE_PATH="$OUTPUT_DIR/reference.json"
AUDIO_PATH="$OUTPUT_DIR/audio.mp3"
REFERENCE_TMP="$REFERENCE_PATH.tmp"
AUDIO_TMP="$AUDIO_PATH.part"

mkdir -p "$OUTPUT_DIR"

jq '{
    schemaVersion: 1,
    session: {
        id,
        title,
        sourceLanguage,
        targetLanguage,
        durationSeconds,
        segmentCount
    },
    segments: [
        .segments[] | {
            index: .segmentIndex,
            speaker,
            text,
            translatedText,
            startMs: .audioStartMs,
            endMs: .audioEndMs,
            confidence
        }
    ]
}' "$SOURCE_JSON" > "$REFERENCE_TMP"
mv "$REFERENCE_TMP" "$REFERENCE_PATH"

if [[ ! -f "$AUDIO_PATH" ]]; then
    AUDIO_URL="$(jq -er '.audioUrl | select(startswith("https://"))' "$SOURCE_JSON")"
    curl \
        --fail \
        --location \
        --retry 3 \
        --continue-at - \
        --output "$AUDIO_TMP" \
        "$AUDIO_URL"
    mv "$AUDIO_TMP" "$AUDIO_PATH"
fi

echo "Prepared private benchmark: $SESSION_ID"
echo "Reference: $REFERENCE_PATH"
echo "Audio: $AUDIO_PATH"
