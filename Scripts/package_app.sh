#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MarkdownPDFRenderer.xcodeproj"
SCHEME="MarkdownPDFRenderer"
CONFIGURATION="${CONFIGURATION:-Debug}"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_NAME="MarkdownPDFRenderer.app"
DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/MarkdownPDFRenderer.XXXXXX")"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
OUTPUT_APP_PATH="$OUTPUT_DIR/$APP_NAME"

cleanup() {
  rm -rf "$DERIVED_DATA_PATH"
}

trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "$OUTPUT_APP_PATH"
cp -R "$BUILT_APP_PATH" "$OUTPUT_APP_PATH"

echo "Packaged app: $OUTPUT_APP_PATH"
