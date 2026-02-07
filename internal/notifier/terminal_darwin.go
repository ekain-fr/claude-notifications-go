//go:build darwin

package notifier

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/777genius/claude-notifications/internal/config"
	"github.com/777genius/claude-notifications/internal/platform"
)

// terminalBundleIDMap maps TERM_PROGRAM values to macOS bundle identifiers
var terminalBundleIDMap = map[string]string{
	"Apple_Terminal": "com.apple.Terminal",
	"iTerm.app":      "com.googlecode.iterm2",
	"WarpTerminal":   "dev.warp.Warp-Stable",
	"kitty":          "net.kovidgoyal.kitty",
	"ghostty":        "com.mitchellh.ghostty",
	"WezTerm":        "com.github.wez.wezterm",
	"Alacritty":      "org.alacritty",
	"Hyper":          "co.zeit.hyper",
	"vscode":         "com.microsoft.VSCode",
}

// GetTerminalBundleID determines the bundle ID of the current terminal.
// Priority:
// 1. configOverride (if provided)
// 2. __CFBundleIdentifier env var (set by some terminals like Warp)
// 3. TERM_PROGRAM env var mapped to known bundle IDs
// 4. Fallback to com.apple.Terminal
func GetTerminalBundleID(configOverride string) string {
	// 1. Use config override if provided
	if configOverride != "" {
		return configOverride
	}

	// 2. Check __CFBundleIdentifier (directly contains bundle ID)
	if bundleID := os.Getenv("__CFBundleIdentifier"); bundleID != "" {
		return bundleID
	}

	// 3. Map TERM_PROGRAM to bundle ID
	if termProgram := os.Getenv("TERM_PROGRAM"); termProgram != "" {
		if bundleID, ok := terminalBundleIDMap[termProgram]; ok {
			return bundleID
		}
	}

	// 4. Fallback to standard Terminal.app
	return "com.apple.Terminal"
}

// GetTerminalNotifierPath returns the path to terminal-notifier binary.
// Priority:
// 1. Embedded in plugin: ${CLAUDE_PLUGIN_ROOT}/bin/terminal-notifier.app/Contents/MacOS/terminal-notifier
// 2. System-installed (via brew): $(which terminal-notifier)
func GetTerminalNotifierPath() (string, error) {
	// 1. Check embedded version in plugin
	pluginRoot := os.Getenv("CLAUDE_PLUGIN_ROOT")
	if pluginRoot != "" {
		embeddedPath := filepath.Join(pluginRoot, "bin",
			"terminal-notifier.app", "Contents", "MacOS", "terminal-notifier")
		if platform.FileExists(embeddedPath) {
			return embeddedPath, nil
		}
	}

	// 2. Check system installation (brew install terminal-notifier)
	if path, err := exec.LookPath("terminal-notifier"); err == nil {
		return path, nil
	}

	return "", fmt.Errorf("terminal-notifier not found: run /claude-notifications-go:notifications-init to install")
}

// IsTerminalNotifierAvailable checks if terminal-notifier is available
func IsTerminalNotifierAvailable() bool {
	_, err := GetTerminalNotifierPath()
	return err == nil
}

// EnsureClaudeNotificationsApp creates ClaudeNotifications.app if it doesn't exist.
// This allows the notification icon to work even when users update the plugin
// without running /claude-notifications-go:notifications-init.
func EnsureClaudeNotificationsApp() error {
	pluginRoot := os.Getenv("CLAUDE_PLUGIN_ROOT")
	if pluginRoot == "" {
		return fmt.Errorf("CLAUDE_PLUGIN_ROOT not set")
	}

	appDir := filepath.Join(pluginRoot, "bin", "ClaudeNotifications.app")

	// Already exists
	if platform.FileExists(filepath.Join(appDir, "Contents", "Info.plist")) {
		return nil
	}

	iconSrc := filepath.Join(pluginRoot, "claude_icon.png")
	if !platform.FileExists(iconSrc) {
		return fmt.Errorf("claude_icon.png not found")
	}

	// Create app structure
	if err := os.MkdirAll(filepath.Join(appDir, "Contents", "MacOS"), 0755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(appDir, "Contents", "Resources"), 0755); err != nil {
		return err
	}

	// Create iconset and convert to icns
	iconsetDir := filepath.Join(os.TempDir(), fmt.Sprintf("claude-%d.iconset", os.Getpid()))
	if err := os.MkdirAll(iconsetDir, 0755); err != nil {
		return err
	}
	defer os.RemoveAll(iconsetDir)

	// Generate icon sizes using sips
	sizes := []struct {
		size int
		name string
	}{
		{16, "icon_16x16.png"},
		{32, "icon_16x16@2x.png"},
		{32, "icon_32x32.png"},
		{64, "icon_32x32@2x.png"},
		{128, "icon_128x128.png"},
		{256, "icon_128x128@2x.png"},
		{256, "icon_256x256.png"},
		{512, "icon_256x256@2x.png"},
	}

	for _, s := range sizes {
		outPath := filepath.Join(iconsetDir, s.name)
		cmd := exec.Command("sips", "-z", fmt.Sprintf("%d", s.size), fmt.Sprintf("%d", s.size), iconSrc, "--out", outPath)
		cmd.Run() // Ignore errors, some sizes may fail
	}

	// Copy original as 512x512
	exec.Command("cp", iconSrc, filepath.Join(iconsetDir, "icon_512x512.png")).Run()

	// Convert to icns
	icnsPath := filepath.Join(appDir, "Contents", "Resources", "AppIcon.icns")
	if err := exec.Command("iconutil", "-c", "icns", iconsetDir, "-o", icnsPath).Run(); err != nil {
		return fmt.Errorf("iconutil failed: %w", err)
	}

	// Create Info.plist
	plist := `<?xml version="1.0" encoding="UTF-8"?>
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
</plist>`
	if err := os.WriteFile(filepath.Join(appDir, "Contents", "Info.plist"), []byte(plist), 0644); err != nil {
		return err
	}

	// Create minimal executable
	execPath := filepath.Join(appDir, "Contents", "MacOS", "claude-notify")
	if err := os.WriteFile(execPath, []byte("#!/bin/bash\nexit 0\n"), 0755); err != nil {
		return err
	}

	// Register with Launch Services
	exec.Command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", appDir).Run()

	return nil
}

// sendLinuxNotification is a stub for macOS.
// On macOS, click-to-focus is handled via terminal-notifier.
func sendLinuxNotification(title, body, appIcon string, cfg *config.Config) error {
	return fmt.Errorf("Linux notifications not available on macOS")
}

// IsDaemonAvailable returns false on macOS (Linux daemon is not applicable).
func IsDaemonAvailable() bool {
	return false
}

// StartDaemon is a no-op on macOS.
func StartDaemon() bool {
	return false
}

// StopDaemon is a no-op on macOS.
func StopDaemon() error {
	return nil
}
