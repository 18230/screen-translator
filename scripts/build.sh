#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_APP="$PROJECT_DIR/.build/package/截屏翻译.app"
mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"
cp "$PROJECT_DIR/Resources/Info.plist" "$OUTPUT_APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -target arm64-apple-macosx15.2 \
  "$PROJECT_DIR"/Sources/*.swift \
  -framework AppKit -framework ScreenCaptureKit -framework Carbon \
  -framework Security -framework CryptoKit -framework ImageIO \
  -o "$OUTPUT_APP/Contents/MacOS/ScreenTranslator"
python3 "$PROJECT_DIR/scripts/sign-app.py" "$OUTPUT_APP"
codesign --verify --strict "$OUTPUT_APP"
echo "$OUTPUT_APP"
