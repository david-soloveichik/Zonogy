#!/bin/bash
# Compiles and signs the optional injection tools into a staging directory; never builds the app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/Native/InstantMinimize"
OUTPUT_DIR="${1:-$PROJECT_DIR/.build/InstantMinimize}"
mkdir -p "$OUTPUT_DIR"

# This feature is Apple Silicon-only; an Intel app build remains usable without it.
if [ "$(uname -m)" != arm64 ]; then
    exit 0
fi

xcrun clang -mmacosx-version-min=15.0 -Wall -Wextra -O2 -arch arm64 \
    -framework Foundation "$SOURCE_DIR/helper.m" -o "$OUTPUT_DIR/Zonogy-helper"
xcrun clang -mmacosx-version-min=15.0 -Wall -O2 -arch arm64e \
    -framework Cocoa "$SOURCE_DIR/loader.m" "$SOURCE_DIR/injector.S" -o "$OUTPUT_DIR/loader"
# Match Dock's arm64e pointer-auth ABI (the same header adjustment used by instantmini).
printf '\x80' | dd of="$OUTPUT_DIR/loader" bs=1 seek=11 count=1 conv=notrunc 2>/dev/null
xcrun clang -mmacosx-version-min=15.0 -Wall -O2 -arch arm64e -dynamiclib \
    -framework Cocoa -Wl,-exported_symbol,_instantmini_patch -Wl,-exported_symbol,_instantmini_verify_v1 \
    "$SOURCE_DIR/payload.m" -o "$OUTPUT_DIR/payload.dylib"
cp "$SOURCE_DIR/lldb_inject.py" "$OUTPUT_DIR/lldb_inject.py"
for binary in Zonogy-helper loader payload.dylib; do
    codesign --force --sign - "$OUTPUT_DIR/$binary"
done
