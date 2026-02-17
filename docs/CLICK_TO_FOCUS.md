# Click-to-Focus

Clicking a notification activates your terminal window — no more hunting for the right window.

## Configuration

In `~/.claude/claude-notifications-go/config.json`:

```json
{
  "notifications": {
    "desktop": {
      "clickToFocus": true,
      "terminalBundleId": ""
    }
  }
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `clickToFocus` | `true` | Enable click-to-focus on macOS and Linux |
| `terminalBundleId` | `""` | macOS only: override auto-detected terminal. Use bundle ID like `com.googlecode.iterm2` |

## macOS

- Automatically detects your terminal (iTerm2, Warp, Terminal.app, kitty, Ghostty, WezTerm, Alacritty)
- Uses `terminal-notifier` (auto-installed via `/claude-notifications-go:init`)
- Falls back to standard notifications if terminal-notifier is unavailable
- Supported terminals: Terminal.app, iTerm2, Warp, kitty, Ghostty, WezTerm, Alacritty, Hyper, VS Code
- To find your terminal's bundle ID: `osascript -e 'id of app "YourTerminal"'`

## Linux

- Uses a background daemon with D-Bus for notification actions
- Automatically detects your terminal and desktop environment
- Supports multiple focus methods with fallback chain:
  - **GNOME**: `activate-window-by-title` extension, Shell Eval, FocusApp (GNOME 45+)
  - **KDE Plasma**: `kdotool`
  - **Sway / wlroots**: `wlrctl`
  - **X11** (XFCE, MATE, Cinnamon, i3, bspwm): `xdotool`
- Supported terminals: GNOME Terminal, Konsole, Alacritty, kitty, WezTerm, Tilix, Terminator, XFCE4 Terminal, MATE Terminal, VS Code
- Falls back to standard notifications if no focus tool is available
