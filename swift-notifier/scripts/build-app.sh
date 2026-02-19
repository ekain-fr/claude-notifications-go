#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$PROJECT_DIR")"

BINARY_NAME="terminal-notifier-modern"
APP_BUNDLE_NAME="ClaudeNotifier"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_BUNDLE="${PROJECT_DIR}/${APP_BUNDLE_NAME}.app"
ICON_SRC="${REPO_ROOT}/claude_icon.png"
ENTITLEMENTS="${PROJECT_DIR}/entitlements.plist"

echo "Building ${BINARY_NAME}..."

# Build universal binary (arm64 + x86_64) for both Apple Silicon and Intel Macs
cd "$PROJECT_DIR"

echo "Building for arm64..."
swift build -c release --arch arm64 2>&1
ARM64_BINARY="${BUILD_DIR}/release/${BINARY_NAME}"
if [ ! -f "$ARM64_BINARY" ]; then
    echo "Error: arm64 binary not found at ${ARM64_BINARY}"
    exit 1
fi

echo "Building for x86_64..."
swift build -c release --arch x86_64 2>&1
X86_BINARY="${BUILD_DIR}/release/${BINARY_NAME}"
if [ ! -f "$X86_BINARY" ]; then
    echo "Error: x86_64 binary not found at ${X86_BINARY}"
    exit 1
fi

# Merge into universal binary
BINARY="${BUILD_DIR}/${BINARY_NAME}-universal"
lipo -create \
    "${BUILD_DIR}/arm64-apple-macosx/release/${BINARY_NAME}" \
    "${BUILD_DIR}/x86_64-apple-macosx/release/${BINARY_NAME}" \
    -output "$BINARY"

echo "Universal binary built successfully: ${BINARY}"
file "$BINARY"

# Assemble .app bundle
echo "Assembling .app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"

# Copy Info.plist
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/"

# Generate app icon if source PNG exists
if [ -f "$ICON_SRC" ]; then
    echo "Generating app icon..."
    ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16 "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16.png" 2>/dev/null || true
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" 2>/dev/null || true
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32.png" 2>/dev/null || true
    sips -z 64 64 "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" 2>/dev/null || true
    sips -z 128 128 "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128.png" 2>/dev/null || true
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" 2>/dev/null || true
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256.png" 2>/dev/null || true
    sips -z 512 512 "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" 2>/dev/null || true
    sips -z 512 512 "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512.png" 2>/dev/null || true

    ICNS_PATH="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    if iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH" 2>/dev/null; then
        echo "App icon generated successfully"
    else
        echo "Warning: could not generate app icon (iconutil failed)"
    fi

    rm -rf "$(dirname "$ICONSET_DIR")"
else
    echo "Warning: icon source not found at ${ICON_SRC}, skipping icon generation"
fi

# Code signing — always use ad-hoc.
# Developer ID Application signing causes macOS to SIGKILL the binary on launch
# (Gatekeeper/AMFI blocks non-notarized Developer ID apps run from CLI).
# Ad-hoc signing works reliably because:
# - The binary is never downloaded directly by users (installed via script/curl)
# - No Gatekeeper check for script-installed binaries
# - UNUserNotificationCenter works correctly with ad-hoc signing
echo "Code signing .app bundle (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || {
    echo "Warning: code signing failed (notifications may require manual permission)"
}

# Register with Launch Services (makes macOS aware of the app and its icon)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_BUNDLE" 2>/dev/null || true
    echo "Registered with Launch Services"
fi

echo ""
echo "Build complete!"
echo "  Binary: ${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"
echo "  Bundle: ${APP_BUNDLE}"
echo ""
echo ""
echo "To install into plugin bin/:"
echo "  cp -R ${APP_BUNDLE} ${REPO_ROOT}/bin/"
