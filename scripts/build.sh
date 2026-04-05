#!/bin/bash

# Build script for Zonogy.app
# Usage: ./scripts/build.sh
# Saves app bundle to root project dir

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Zonogy"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Build release executable
cd "$PROJECT_DIR"
swift build -c release

# Remove existing app bundle if present
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$PROJECT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy resources
cp "$PROJECT_DIR/Resources/defaults.json" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_DIR/Resources/icon_menubar.svg" "$APP_BUNDLE/Contents/Resources/"

# Create app icon from PNG
echo "Creating app icon..."
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate icon sizes
sips -z 16 16     "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -z 32 32     "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 64 64     "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -z 256 256   "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -z 512 512   "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$PROJECT_DIR/Resources/icon5.png" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

# Convert to icns
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# Code sign the app (ad-hoc signature)
echo "Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To run: open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
