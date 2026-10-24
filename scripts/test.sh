#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  "$PROJECT_DIR/Sources/TranslationClient.swift" "$PROJECT_DIR/Sources/ImagePipeline.swift" \
  "$PROJECT_DIR/Tests/ProtocolTests.swift" \
  -framework AppKit -framework CryptoKit -framework ImageIO \
  -o "$PROJECT_DIR/.build/ProtocolTests"
"$PROJECT_DIR/.build/ProtocolTests"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  "$PROJECT_DIR/Sources/ShortcutKey.swift" "$PROJECT_DIR/Tests/ShortcutTests.swift" \
  -framework AppKit -framework Carbon -o "$PROJECT_DIR/.build/ShortcutTests"
"$PROJECT_DIR/.build/ShortcutTests"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  "$PROJECT_DIR/Sources/CaptureFailure.swift" "$PROJECT_DIR/Tests/CaptureFailureTests.swift" \
  -framework ScreenCaptureKit -o "$PROJECT_DIR/.build/CaptureFailureTests"
"$PROJECT_DIR/.build/CaptureFailureTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$PROJECT_DIR/Sources/Capture.swift" "$PROJECT_DIR/Sources/ImagePipeline.swift" "$PROJECT_DIR/Sources/TranslationClient.swift" \
  "$PROJECT_DIR/Tests/SelectionRenderTests.swift" \
  -framework AppKit -framework ScreenCaptureKit -framework CryptoKit -framework ImageIO \
  -o "$PROJECT_DIR/.build/SelectionRenderTests"
"$PROJECT_DIR/.build/SelectionRenderTests"
