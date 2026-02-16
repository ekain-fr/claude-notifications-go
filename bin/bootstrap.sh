#!/bin/bash
# bootstrap.sh - One-command install/update for claude-notifications plugin
# Usage: curl -fsSL https://raw.githubusercontent.com/777genius/claude-notifications-go/main/bin/bootstrap.sh | bash

set -euo pipefail

# Colors and formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Constants
REPO="777genius/claude-notifications-go"
MARKETPLACE_NAME="claude-notifications-go"
PLUGIN_NAME="claude-notifications-go"
PLUGIN_KEY="${PLUGIN_NAME}@${MARKETPLACE_NAME}"
INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/${REPO}/main/bin/install.sh}"

# Paths — use :- for unset, then guard against explicitly empty CLAUDE_HOME
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
if [ -z "$CLAUDE_HOME" ]; then
    CLAUDE_HOME="$HOME/.claude"
fi
INSTALLED_JSON="${CLAUDE_HOME}/plugins/installed_plugins.json"
CACHE_DIR="${CLAUDE_HOME}/plugins/cache/${MARKETPLACE_NAME}"

# State
PLUGIN_ROOT=""
_BOOTSTRAP_TMP=""  # temp file path for trap (set -u safe)

# ──────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD} Claude Notifications — Bootstrap Installer${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""
}

# ──────────────────────────────────────────────

check_prerequisites() {
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}✗ claude CLI not found in PATH${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}Install Claude Code first:${NC}" >&2
        echo -e "  npm install -g @anthropic-ai/claude-code" >&2
        echo "" >&2
        exit 1
    fi
    echo -e "${GREEN}✓${NC} claude CLI found"

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo -e "${RED}✗ curl or wget required${NC}" >&2
        exit 1
    fi
}

# ──────────────────────────────────────────────

detect_platform() {
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"

    case "$os" in
        darwin)  PLATFORM="macOS" ;;
        linux)   PLATFORM="Linux" ;;
        mingw*|msys*|cygwin*) PLATFORM="Windows (Git Bash)" ;;
        *)       PLATFORM="$os" ;;
    esac

    echo -e "${BLUE}Platform:${NC} ${PLATFORM}"
}

# ──────────────────────────────────────────────

setup_marketplace() {
    echo ""
    echo -e "${BLUE}📦 Setting up marketplace...${NC}"

    local output
    # Try adding marketplace — if already added, update instead
    # </dev/null prevents stdin conflicts when running via `curl | bash`
    if output=$(claude plugin marketplace add "$REPO" </dev/null 2>&1); then
        echo -e "${GREEN}✓${NC} Marketplace added"
    else
        if echo "$output" | grep -qi "already"; then
            echo -e "${BLUE}  Marketplace already added, updating...${NC}"
            if claude plugin marketplace update "$MARKETPLACE_NAME" </dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} Marketplace updated"
            else
                # Update may fail if already up-to-date — that's OK
                echo -e "${GREEN}✓${NC} Marketplace is up to date"
            fi
        else
            echo -e "${YELLOW}⚠ Marketplace add output: ${output}${NC}"
            echo -e "${YELLOW}  Continuing anyway...${NC}"
        fi
    fi
}

# ──────────────────────────────────────────────

install_plugin() {
    echo ""
    echo -e "${BLUE}📦 Installing plugin...${NC}"

    # Remember old version directories before clearing cache.
    # After install, we create symlinks from old versions to the new one
    # so that the running Claude Code instance can still find hook-wrapper.sh
    # at the old path (it caches the path in memory until restart).
    local version_dir="${CACHE_DIR}/${MARKETPLACE_NAME}"
    local old_versions=()
    if [ -d "$version_dir" ]; then
        for d in "$version_dir"/*/; do
            # Skip symlinks from previous bootstrap runs, only collect real dirs
            [ -d "$d" ] && [ ! -L "${d%/}" ] && old_versions+=("$(basename "$d")")
        done
    fi

    # Clear plugin cache to work around update bug (#19197)
    if [ -n "$CACHE_DIR" ] && [ "$CACHE_DIR" != "/" ] && [ -d "$CACHE_DIR" ]; then
        echo -e "${BLUE}  Clearing plugin cache...${NC}"
        rm -rf "$CACHE_DIR" 2>/dev/null || true
    fi

    local output
    if output=$(claude plugin install "$PLUGIN_KEY" </dev/null 2>&1); then
        echo -e "${GREEN}✓${NC} Plugin installed"
    else
        if echo "$output" | grep -qi "already installed"; then
            echo -e "${GREEN}✓${NC} Plugin already installed"
        else
            echo -e "${RED}✗ Plugin install failed${NC}" >&2
            echo -e "${YELLOW}Output: ${output}${NC}" >&2
            exit 1
        fi
    fi

    # Create symlinks from old version dirs to the new one so running
    # Claude Code instances don't break before restart
    if [ -d "$version_dir" ] && [ ${#old_versions[@]} -gt 0 ]; then
        local new_version=""
        for d in "$version_dir"/*/; do
            [ -d "$d" ] && [ ! -L "${d%/}" ] && new_version="$(basename "$d")" && break
        done

        if [ -n "$new_version" ]; then
            for old_ver in "${old_versions[@]}"; do
                if [ "$old_ver" != "$new_version" ] && [ ! -e "$version_dir/$old_ver" ]; then
                    # Relative symlink (both paths in same directory)
                    ln -s "$new_version" "$version_dir/$old_ver" 2>/dev/null || true
                    echo -e "${BLUE}  Symlink: ${old_ver} → ${new_version} (for running session)${NC}"
                fi
            done
        fi
    fi
}

# ──────────────────────────────────────────────

find_plugin_root() {
    echo ""
    echo -e "${BLUE}🔍 Locating plugin directory...${NC}"

    if [ ! -f "$INSTALLED_JSON" ]; then
        echo -e "${RED}✗ installed_plugins.json not found at ${INSTALLED_JSON}${NC}" >&2
        echo -e "${YELLOW}  Try restarting Claude Code and running this script again.${NC}" >&2
        exit 1
    fi

    # Try jq first (clean JSON parsing)
    if command -v jq &>/dev/null; then
        PLUGIN_ROOT=$(jq -r ".plugins[\"${PLUGIN_KEY}\"][0].installPath // empty" "$INSTALLED_JSON" 2>/dev/null || true)
        if [ "$PLUGIN_ROOT" = "null" ]; then
            PLUGIN_ROOT=""
        fi
    fi

    # Fallback: python3 (available on macOS and most Linux)
    # Pass paths as arguments to avoid shell injection in python code
    if [ -z "$PLUGIN_ROOT" ] && command -v python3 &>/dev/null; then
        PLUGIN_ROOT=$(python3 - "$INSTALLED_JSON" "$PLUGIN_KEY" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    entries = d.get('plugins', {}).get(sys.argv[2], [])
    if entries:
        print(entries[0].get('installPath', ''))
except Exception:
    pass
PYEOF
)
    fi

    # Fallback: grep + sed (works everywhere)
    if [ -z "$PLUGIN_ROOT" ]; then
        # Find the installPath that's inside the claude-notifications-go cache dir
        # Note: JSON may have whitespace after colon — "installPath": "..." or "installPath":"..."
        PLUGIN_ROOT=$(grep -o '"installPath"[[:space:]]*:[[:space:]]*"[^"]*'"${MARKETPLACE_NAME}"'[^"]*"' "$INSTALLED_JSON" 2>/dev/null \
            | head -1 \
            | sed 's/"installPath"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
    fi

    if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
        echo -e "${RED}✗ Could not find plugin install path${NC}" >&2
        echo -e "${YELLOW}  installed_plugins.json may not contain the plugin entry yet.${NC}" >&2
        echo -e "${YELLOW}  Try: claude plugin install ${PLUGIN_KEY}${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Plugin root: ${PLUGIN_ROOT}"
}

# ──────────────────────────────────────────────

download_binary() {
    echo ""
    echo -e "${BLUE}📦 Downloading notification binary...${NC}"

    local target_dir="${PLUGIN_ROOT}/bin"
    if ! mkdir -p "$target_dir" 2>/dev/null; then
        echo -e "${RED}✗ Cannot create directory: ${target_dir}${NC}" >&2
        exit 1
    fi

    # Download install.sh to a temp file, verify it's non-empty, then run
    # Set trap BEFORE mktemp to avoid race condition on Ctrl+C
    trap 'rm -f "$_BOOTSTRAP_TMP" 2>/dev/null' EXIT INT TERM
    # Validate TMPDIR exists; fall back to /tmp if it doesn't
    local tmp_base="${TMPDIR:-/tmp}"
    if [ ! -d "$tmp_base" ]; then
        tmp_base="/tmp"
    fi
    _BOOTSTRAP_TMP="$(mktemp "${tmp_base}/bootstrap-install-XXXXXX")"
    local tmp_script="$_BOOTSTRAP_TMP"

    local downloaded=false
    if command -v curl &>/dev/null; then
        curl -fsSL "$INSTALL_SCRIPT_URL" -o "$tmp_script" 2>/dev/null && downloaded=true
    elif command -v wget &>/dev/null; then
        wget -q "$INSTALL_SCRIPT_URL" -O "$tmp_script" 2>/dev/null && downloaded=true
    fi

    if [ "$downloaded" != true ] || [ ! -s "$tmp_script" ]; then
        echo -e "${RED}✗ Failed to download install.sh${NC}" >&2
        echo -e "${YELLOW}  URL: ${INSTALL_SCRIPT_URL}${NC}" >&2
        exit 1
    fi

    # </dev/null prevents stdin conflicts when running via `curl | bash`
    local install_exit=0
    INSTALL_TARGET_DIR="$target_dir" bash "$tmp_script" </dev/null || install_exit=$?

    if [ $install_exit -ne 0 ]; then
        echo -e "${RED}✗ Binary installation failed (exit code: ${install_exit})${NC}" >&2
        exit 1
    fi
}

# ──────────────────────────────────────────────

print_success() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} ✓ Bootstrap Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  1. ${YELLOW}Restart Claude Code${NC} (exit and reopen)"
    echo -e "  2. Run ${BOLD}/claude-notifications-go:settings${NC} to configure sounds"
    echo ""
    echo -e "${BLUE}One-liner to update in the future (same as install):${NC}"
    echo -e "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/bin/bootstrap.sh | bash"
    echo ""
}

# ──────────────────────────────────────────────

main() {
    print_header
    check_prerequisites
    detect_platform
    setup_marketplace
    install_plugin
    find_plugin_root
    download_binary
    print_success
}

main "$@"
