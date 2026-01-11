#!/bin/sh
# hook-wrapper.sh - POSIX-compatible wrapper for lazy binary download
# Checks if binary exists, downloads if missing, runs hook
#
# This wrapper enables auto-download of binaries after plugin auto-update.
# Claude Code plugins don't have post-install hooks, so we use lazy loading.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine binary path based on platform
# Windows: use .bat wrapper; Unix: use native binary
IS_WINDOWS=false
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        BINARY="$SCRIPT_DIR/claude-notifications.bat"
        IS_WINDOWS=true
        ;;
    *)
        BINARY="$SCRIPT_DIR/claude-notifications"
        ;;
esac

# Check if binary exists
# Windows: use -f (file exists) since .bat files aren't marked executable
# Unix: use -x (executable)
if [ "$IS_WINDOWS" = "true" ]; then
    BINARY_EXISTS=$([ -f "$BINARY" ] && echo "yes" || echo "no")
else
    BINARY_EXISTS=$([ -x "$BINARY" ] && echo "yes" || echo "no")
fi

# Download if missing
if [ "$BINARY_EXISTS" = "no" ]; then
    # Download binary (silent, non-blocking on failure)
    INSTALL_TARGET_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 || true

    # Re-check after download
    if [ "$IS_WINDOWS" = "true" ]; then
        BINARY_EXISTS=$([ -f "$BINARY" ] && echo "yes" || echo "no")
    else
        BINARY_EXISTS=$([ -x "$BINARY" ] && echo "yes" || echo "no")
    fi
fi

# Run the hook (or fail gracefully if still missing)
if [ "$BINARY_EXISTS" = "yes" ]; then
    exec "$BINARY" "$@"
else
    # Binary still missing - exit silently to not block Claude
    exit 0
fi
