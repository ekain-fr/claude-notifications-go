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

Auto-detects your terminal via `TERM_PROGRAM` / `__CFBundleIdentifier`. Uses `terminal-notifier` (auto-installed via `/claude-notifications-go:init`).

| Terminal | Focus method |
|----------|-------------|
| Ghostty | AXDocument (OSC 7 CWD) with retry backoff |
| VS Code / Insiders | AXTitle via focus-window subcommand |
| iTerm2, Warp, kitty, WezTerm, Alacritty, Hyper, Apple Terminal | AppleScript (window title matching) |
| Any other (custom `terminalBundleId`) | AppleScript (window title matching) |

To find your terminal's bundle ID: `osascript -e 'id of app "YourTerminal"'`

### Permissions

**Ghostty** requires **Accessibility** permission — to enumerate windows via AXDocument. Prompted automatically on first use.

**VS Code** requires two permissions:

- **Accessibility** — to enumerate and raise windows via the AX API
- **Screen Recording** — to read window titles across Spaces (macOS 10.15+)

Both are requested automatically on first use. Without Screen Recording, clicking a notification still activates VS Code but raises whichever window was last active rather than the project-specific one.

Other terminals use AppleScript and require no additional permissions.

## Linux

Uses a background D-Bus daemon. Auto-detects terminal and compositor.

| Terminal | Supported compositors |
|----------|----------------------|
| VS Code | GNOME, KDE, Sway, X11 |
| GNOME Terminal, Konsole, Alacritty, kitty, WezTerm, Tilix, Terminator, XFCE4 Terminal, MATE Terminal | GNOME, KDE, Sway, X11 |
| Any other | Fallback by name |

Focus methods (tried in order):

1. **GNOME**: `activate-window-by-title` extension, Shell Eval, FocusApp (GNOME 45+)
2. **Sway / wlroots**: `wlrctl`
3. **KDE Plasma**: `kdotool`
4. **X11** (XFCE, MATE, Cinnamon, i3, bspwm): `xdotool`

Falls back to standard notifications if no focus tool is available.

## Multiplexers

On both macOS and Linux, click-to-focus supports **tmux** and **zellij** — clicking a notification switches to the correct session/pane/tab.

## Windows

Notifications only, no click-to-focus.
