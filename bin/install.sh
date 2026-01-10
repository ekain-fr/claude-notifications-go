#!/bin/bash
# install.sh - Auto-installer for claude-notifications binaries
# Downloads the appropriate binary from GitHub Releases

set -e

# Colors and formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub repository
REPO="777genius/claude-notifications-go"
RELEASE_URL="https://github.com/${REPO}/releases/latest/download"
CHECKSUMS_URL="${RELEASE_URL}/checksums.txt"

# Detect platform and architecture
detect_platform() {
    local os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    local arch="$(uname -m)"

    case "$os" in
        darwin)
            PLATFORM="darwin"
            ;;
        linux)
            PLATFORM="linux"
            ;;
        mingw*|msys*|cygwin*)
            PLATFORM="windows"
            ;;
        *)
            echo -e "${RED}✗ Unsupported OS: $os${NC}" >&2
            exit 1
            ;;
    esac

    case "$arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        arm64|aarch64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}✗ Unsupported architecture: $arch${NC}" >&2
            exit 1
            ;;
    esac

    # Construct binary names
    if [ "$PLATFORM" = "windows" ]; then
        BINARY_NAME="claude-notifications-${PLATFORM}-${ARCH}.exe"
        SOUND_PREVIEW_NAME="sound-preview-${PLATFORM}-${ARCH}.exe"
        LIST_DEVICES_NAME="list-devices-${PLATFORM}-${ARCH}.exe"
    else
        BINARY_NAME="claude-notifications-${PLATFORM}-${ARCH}"
        SOUND_PREVIEW_NAME="sound-preview-${PLATFORM}-${ARCH}"
        LIST_DEVICES_NAME="list-devices-${PLATFORM}-${ARCH}"
    fi

    BINARY_PATH="${SCRIPT_DIR}/${BINARY_NAME}"
    SOUND_PREVIEW_PATH="${SCRIPT_DIR}/${SOUND_PREVIEW_NAME}"
    LIST_DEVICES_PATH="${SCRIPT_DIR}/${LIST_DEVICES_NAME}"
    CHECKSUMS_PATH="${SCRIPT_DIR}/.checksums.txt"
}

# Get file size with multiple fallbacks
get_file_size() {
    local file="$1"

    # Try BSD stat (macOS)
    if stat -f%z "$file" 2>/dev/null; then
        return 0
    fi

    # Try GNU stat (Linux)
    if stat -c%s "$file" 2>/dev/null; then
        return 0
    fi

    # Fallback to wc -c (universal)
    wc -c < "$file" 2>/dev/null || echo "0"
}

# Check if GitHub is accessible
check_github_availability() {
    if command -v curl &> /dev/null; then
        if ! curl -s --max-time 5 -I https://github.com &> /dev/null; then
            echo -e "${RED}✗ Cannot reach GitHub${NC}" >&2
            echo -e "${YELLOW}Possible issues:${NC}" >&2
            echo -e "  - No internet connection" >&2
            echo -e "  - GitHub is down" >&2
            echo -e "  - Firewall/proxy blocking access" >&2
            return 1
        fi
    fi
    return 0
}

# Check if binary already exists
check_existing() {
    if [ -f "$BINARY_PATH" ]; then
        echo -e "${GREEN}✓${NC} Binary already installed: ${BOLD}${BINARY_NAME}${NC}"
        echo ""
        return 0
    fi
    return 1
}

# Download a utility binary (sound-preview, list-devices)
download_utility() {
    local util_name="$1"
    local util_path="$2"
    local url="${RELEASE_URL}/${util_name}"

    # Skip if already exists
    if [ -f "$util_path" ]; then
        echo -e "${GREEN}✓${NC} ${util_name} already installed"
        return 0
    fi

    echo -e "${BLUE}📦 Downloading ${util_name}...${NC}"

    if command -v curl &> /dev/null; then
        if curl -fsSL "$url" -o "$util_path" 2>/dev/null; then
            if [ -f "$util_path" ] && [ "$(get_file_size "$util_path")" -gt 100000 ]; then
                chmod +x "$util_path" 2>/dev/null || true
                echo -e "${GREEN}✓${NC} ${util_name} downloaded"
                return 0
            fi
        fi
    elif command -v wget &> /dev/null; then
        if wget -q "$url" -O "$util_path" 2>/dev/null; then
            if [ -f "$util_path" ] && [ "$(get_file_size "$util_path")" -gt 100000 ]; then
                chmod +x "$util_path" 2>/dev/null || true
                echo -e "${GREEN}✓${NC} ${util_name} downloaded"
                return 0
            fi
        fi
    fi

    # Not critical - just warn
    rm -f "$util_path" 2>/dev/null
    echo -e "${YELLOW}⚠${NC} Could not download ${util_name} (optional utility)"
    return 1
}

# Download utility binaries (sound-preview, list-devices)
download_utilities() {
    echo ""
    echo -e "${BLUE}📦 Downloading utility binaries...${NC}"

    download_utility "$SOUND_PREVIEW_NAME" "$SOUND_PREVIEW_PATH"
    download_utility "$LIST_DEVICES_NAME" "$LIST_DEVICES_PATH"

    # Create symlinks for utilities
    create_utility_symlink "sound-preview" "$SOUND_PREVIEW_NAME" "$SOUND_PREVIEW_PATH"
    create_utility_symlink "list-devices" "$LIST_DEVICES_NAME" "$LIST_DEVICES_PATH"
}

# Create symlink for a utility binary
create_utility_symlink() {
    local util_base="$1"
    local util_name="$2"
    local util_path="$3"

    if [ ! -f "$util_path" ]; then
        return 1
    fi

    local symlink_path="${SCRIPT_DIR}/${util_base}"

    # Remove old symlink if exists
    rm -f "$symlink_path" 2>/dev/null || true

    if [ "$PLATFORM" = "windows" ]; then
        # Windows: create .bat wrapper
        local bat_path="${symlink_path}.bat"
        cat > "$bat_path" << EOF
@echo off
setlocal
set SCRIPT_DIR=%~dp0
"%SCRIPT_DIR%${util_name}" %*
EOF
        return 0
    fi

    # Unix: create symlink
    if ln -s "$util_name" "$symlink_path" 2>/dev/null; then
        return 0
    fi

    # Fallback: copy
    cp "$util_path" "$symlink_path" 2>/dev/null || true
    chmod +x "$symlink_path" 2>/dev/null || true
}

# Download checksums file
download_checksums() {
    echo -e "${BLUE}📝 Downloading checksums...${NC}"

    if command -v curl &> /dev/null; then
        if curl -fsSL "$CHECKSUMS_URL" -o "$CHECKSUMS_PATH" 2>/dev/null; then
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget -q "$CHECKSUMS_URL" -O "$CHECKSUMS_PATH" 2>/dev/null; then
            return 0
        fi
    fi

    # Checksums optional - just warn
    echo -e "${YELLOW}⚠ Could not download checksums (verification will be skipped)${NC}"
    return 1
}

# Download binary with progress bar
download_binary() {
    local url="${RELEASE_URL}/${BINARY_NAME}"

    echo -e "${BLUE}📦 Downloading ${BOLD}${BINARY_NAME}${NC}${BLUE}...${NC}"
    echo -e "${BLUE}   From: ${url}${NC}"
    echo ""

    # Try curl first (with progress bar)
    if command -v curl &> /dev/null; then
        # Capture HTTP status
        local http_code=$(curl -w "%{http_code}" -fL --progress-bar "$url" -o "$BINARY_PATH" 2>&1 | tail -1)

        if [ -f "$BINARY_PATH" ] && [ "$(get_file_size "$BINARY_PATH")" -gt 100000 ]; then
            echo ""
            return 0
        else
            # Analyze failure
            rm -f "$BINARY_PATH"

            if echo "$http_code" | grep -q "404"; then
                echo ""
                echo -e "${RED}✗ Binary not found (404)${NC}" >&2
                echo ""
                echo -e "${YELLOW}This usually means the release is still building.${NC}" >&2
                echo -e "${YELLOW}Check build status at:${NC}" >&2
                echo -e "  https://github.com/${REPO}/actions" >&2
                echo ""
                echo -e "${YELLOW}Wait a few minutes and try again.${NC}" >&2
            elif echo "$http_code" | grep -qE "^5[0-9]{2}"; then
                echo ""
                echo -e "${RED}✗ GitHub server error (${http_code})${NC}" >&2
                echo -e "${YELLOW}GitHub may be experiencing issues. Try again later.${NC}" >&2
            else
                echo ""
                echo -e "${RED}✗ Download failed${NC}" >&2
                echo -e "${YELLOW}Check your internet connection and try again.${NC}" >&2
            fi
            return 1
        fi

    # Fallback to wget
    elif command -v wget &> /dev/null; then
        if wget --show-progress -q "$url" -O "$BINARY_PATH" 2>&1; then
            if [ -f "$BINARY_PATH" ] && [ "$(get_file_size "$BINARY_PATH")" -gt 100000 ]; then
                echo ""
                return 0
            fi
        fi

        rm -f "$BINARY_PATH"
        echo ""
        echo -e "${RED}✗ Download failed${NC}" >&2
        return 1

    else
        echo -e "${RED}✗ Error: curl or wget required for installation${NC}" >&2
        echo -e "${YELLOW}Please install curl or wget and try again${NC}" >&2
        return 1
    fi
}

# Verify checksum
verify_checksum() {
    if [ ! -f "$CHECKSUMS_PATH" ]; then
        echo -e "${YELLOW}⚠ Skipping checksum verification (checksums.txt not available)${NC}"
        return 0
    fi

    echo -e "${BLUE}🔒 Verifying checksum...${NC}"

    # Extract expected checksum for our binary
    local expected_sum=$(grep "$BINARY_NAME" "$CHECKSUMS_PATH" 2>/dev/null | awk '{print $1}')

    if [ -z "$expected_sum" ]; then
        echo -e "${YELLOW}⚠ Checksum not found for ${BINARY_NAME} (skipping)${NC}"
        return 0
    fi

    # Calculate actual checksum
    local actual_sum=""
    if command -v shasum &> /dev/null; then
        actual_sum=$(shasum -a 256 "$BINARY_PATH" 2>/dev/null | awk '{print $1}')
    elif command -v sha256sum &> /dev/null; then
        actual_sum=$(sha256sum "$BINARY_PATH" 2>/dev/null | awk '{print $1}')
    else
        echo -e "${YELLOW}⚠ sha256sum not available (skipping checksum)${NC}"
        return 0
    fi

    if [ "$expected_sum" = "$actual_sum" ]; then
        echo -e "${GREEN}✓ Checksum verified${NC}"
        return 0
    else
        echo -e "${RED}✗ Checksum mismatch!${NC}" >&2
        echo -e "${RED}  Expected: ${expected_sum}${NC}" >&2
        echo -e "${RED}  Got:      ${actual_sum}${NC}" >&2
        echo -e "${YELLOW}The downloaded file may be corrupted. Try again.${NC}" >&2
        rm -f "$BINARY_PATH"
        return 1
    fi
}

# Verify downloaded binary
verify_binary() {
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}✗ Binary file not found after download${NC}" >&2
        return 1
    fi

    local size=$(get_file_size "$BINARY_PATH")

    # Check minimum size (1MB)
    if [ "$size" -lt 1000000 ]; then
        echo -e "${RED}✗ Downloaded file too small (${size} bytes)${NC}" >&2
        echo -e "${YELLOW}This might be an error page. Check your internet connection.${NC}" >&2
        rm -f "$BINARY_PATH"
        return 1
    fi

    echo -e "${GREEN}✓ Size check passed${NC} (${size} bytes)"

    # Verify checksum
    if ! verify_checksum; then
        return 1
    fi

    return 0
}

# Make binary executable
make_executable() {
    chmod +x "$BINARY_PATH" 2>/dev/null || true
}

# Create symlink for hooks
create_symlink() {
    # On Windows, create a .bat wrapper instead of symlink
    if [ "$PLATFORM" = "windows" ]; then
        local bat_path="${SCRIPT_DIR}/claude-notifications.bat"

        # Remove old .bat file if exists
        rm -f "$bat_path" 2>/dev/null || true

        # Create .bat wrapper that calls the platform-specific binary
        cat > "$bat_path" << EOF
@echo off
REM claude-notifications Windows wrapper
REM Automatically runs the platform-specific binary

setlocal
set SCRIPT_DIR=%~dp0
"%SCRIPT_DIR%${BINARY_NAME}" %*
EOF

        if [ -f "$bat_path" ]; then
            echo -e "${GREEN}✓ Created wrapper${NC} claude-notifications.bat → ${BINARY_NAME}"
            return 0
        else
            echo -e "${YELLOW}⚠ Could not create .bat wrapper (hooks may not work)${NC}"
            return 1
        fi
    fi

    # Unix: create symlink or copy
    local symlink_path="${SCRIPT_DIR}/claude-notifications"

    # Remove old symlink if exists
    rm -f "$symlink_path" 2>/dev/null || true

    # Create symlink pointing to platform-specific binary
    if ln -s "$BINARY_NAME" "$symlink_path" 2>/dev/null; then
        echo -e "${GREEN}✓ Created symlink${NC} claude-notifications → ${BINARY_NAME}"
        return 0
    else
        # Fallback: copy if symlink fails (some systems don't support symlinks)
        if cp "$BINARY_PATH" "$symlink_path" 2>/dev/null; then
            chmod +x "$symlink_path" 2>/dev/null || true
            echo -e "${GREEN}✓ Created copy${NC} claude-notifications (symlink not supported)"
            return 0
        fi

        echo -e "${YELLOW}⚠ Could not create symlink/copy (hooks may not work)${NC}"
        return 1
    fi
}

# Cleanup temporary files
cleanup() {
    rm -f "$CHECKSUMS_PATH" 2>/dev/null || true
}

# Download terminal-notifier for macOS (enables click-to-focus)
download_terminal_notifier() {
    local NOTIFIER_URL="https://github.com/julienXX/terminal-notifier/releases/download/2.0.0/terminal-notifier-2.0.0.zip"
    local NOTIFIER_APP="${SCRIPT_DIR}/terminal-notifier.app"
    local TEMP_ZIP="/tmp/terminal-notifier-$$.zip"

    # Check if already installed
    if [ -d "$NOTIFIER_APP" ]; then
        echo -e "${GREEN}✓${NC} terminal-notifier already installed"
        return 0
    fi

    echo ""
    echo -e "${BLUE}📦 Installing terminal-notifier (click-to-focus support)...${NC}"

    # Download
    if command -v curl &> /dev/null; then
        if ! curl -fsSL "$NOTIFIER_URL" -o "$TEMP_ZIP" 2>/dev/null; then
            echo -e "${YELLOW}⚠ Could not download terminal-notifier (click-to-focus will be disabled)${NC}"
            return 1
        fi
    elif command -v wget &> /dev/null; then
        if ! wget -q "$NOTIFIER_URL" -O "$TEMP_ZIP" 2>/dev/null; then
            echo -e "${YELLOW}⚠ Could not download terminal-notifier (click-to-focus will be disabled)${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠ curl or wget required for terminal-notifier${NC}"
        return 1
    fi

    # Extract
    if ! unzip -q "$TEMP_ZIP" -d "${SCRIPT_DIR}/" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Could not extract terminal-notifier${NC}"
        rm -f "$TEMP_ZIP"
        return 1
    fi

    # Cleanup
    rm -f "$TEMP_ZIP"

    # Verify
    if [ -d "$NOTIFIER_APP" ]; then
        echo -e "${GREEN}✓${NC} terminal-notifier installed (click-to-focus enabled)"
        return 0
    else
        echo -e "${YELLOW}⚠ terminal-notifier extraction failed${NC}"
        return 1
    fi
}

# Create ClaudeNotifications.app for custom notification icon
create_claude_notifications_app() {
    local APP_DIR="${SCRIPT_DIR}/ClaudeNotifications.app"
    local PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
    local ICON_SRC="${PLUGIN_ROOT}/claude_icon.png"

    # Check if already created
    if [ -d "$APP_DIR" ]; then
        echo -e "${GREEN}✓${NC} ClaudeNotifications.app already exists"
        return 0
    fi

    # Check if icon exists
    if [ ! -f "$ICON_SRC" ]; then
        echo -e "${YELLOW}⚠ Claude icon not found at ${ICON_SRC}${NC}"
        return 1
    fi

    echo -e "${BLUE}🎨 Creating ClaudeNotifications.app (notification icon)...${NC}"

    # Create app structure
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"

    # Create iconset from PNG
    local ICONSET_DIR="/tmp/claude-$$.iconset"
    mkdir -p "$ICONSET_DIR"

    # Generate different icon sizes
    sips -z 16 16 "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16.png" 2>/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" 2>/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32.png" 2>/dev/null
    sips -z 64 64 "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" 2>/dev/null
    sips -z 128 128 "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128.png" 2>/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" 2>/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256.png" 2>/dev/null
    sips -z 512 512 "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" 2>/dev/null
    cp "$ICON_SRC" "$ICONSET_DIR/icon_512x512.png" 2>/dev/null

    # Convert to icns
    if ! iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Could not create app icon${NC}"
        rm -rf "$ICONSET_DIR" "$APP_DIR"
        return 1
    fi

    rm -rf "$ICONSET_DIR"

    # Create Info.plist
    cat > "$APP_DIR/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>claude-notify</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.notifications</string>
    <key>CFBundleName</key>
    <string>Claude Notifications</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST_EOF

    # Create minimal executable
    cat > "$APP_DIR/Contents/MacOS/claude-notify" << 'EXEC_EOF'
#!/bin/bash
exit 0
EXEC_EOF
    chmod +x "$APP_DIR/Contents/MacOS/claude-notify"

    # Register with Launch Services
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

    echo -e "${GREEN}✓${NC} ClaudeNotifications.app created (Claude icon in notifications)"
    return 0
}

# Main installation flow
main() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} Claude Notifications - Binary Setup${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    # Detect platform
    detect_platform
    echo -e "${BLUE}Platform:${NC} ${PLATFORM}-${ARCH}"
    echo -e "${BLUE}Binary:${NC}   ${BINARY_NAME}"
    echo ""

    # Check if already installed
    if check_existing; then
        # Even if binary exists, ensure symlink is created
        create_symlink

        # Download utility binaries (sound-preview, list-devices)
        download_utilities

        # On macOS, also check terminal-notifier and create notification app
        if [ "$PLATFORM" = "darwin" ]; then
            download_terminal_notifier
            create_claude_notifications_app
        fi

        echo -e "${GREEN}✓ Setup complete${NC}"
        echo ""
        return 0
    fi

    # Check GitHub availability
    if ! check_github_availability; then
        echo ""
        exit 1
    fi

    # Download checksums (optional)
    download_checksums

    # Download
    if ! download_binary; then
        cleanup
        echo ""
        echo -e "${RED}========================================${NC}"
        echo -e "${RED} Installation Failed${NC}"
        echo -e "${RED}========================================${NC}"
        echo ""
        echo -e "${YELLOW}Additional troubleshooting:${NC}"
        echo -e "  1. Wait a few minutes if release is building"
        echo -e "  2. Check: https://github.com/${REPO}/releases"
        echo -e "  3. Manual download: https://github.com/${REPO}/releases/latest"
        echo ""
        exit 1
    fi

    # Verify
    if ! verify_binary; then
        cleanup
        echo ""
        echo -e "${RED}========================================${NC}"
        echo -e "${RED} Verification Failed${NC}"
        echo -e "${RED}========================================${NC}"
        echo ""
        exit 1
    fi

    # Make executable
    make_executable

    # Create symlink for hooks to use
    create_symlink

    # Download utility binaries (sound-preview, list-devices)
    download_utilities

    # On macOS, download terminal-notifier and create notification app
    if [ "$PLATFORM" = "darwin" ]; then
        download_terminal_notifier
        create_claude_notifications_app
    fi

    # Cleanup
    cleanup

    # Success message
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} Binary downloaded: ${BOLD}${BINARY_NAME}${NC}"
    echo -e "${GREEN}✓${NC} Utilities: sound-preview, list-devices"
    echo -e "${GREEN}✓${NC} Location: ${SCRIPT_DIR}/"
    echo -e "${GREEN}✓${NC} Checksum verified"
    echo -e "${GREEN}✓${NC} Symlinks created"
    if [ "$PLATFORM" = "darwin" ]; then
        echo -e "${GREEN}✓${NC} terminal-notifier installed (click-to-focus)"
        echo -e "${GREEN}✓${NC} Claude icon configured for notifications"
    fi
    echo -e "${GREEN}✓${NC} Ready to use!"
    echo ""
}

# Run main function
main "$@"
