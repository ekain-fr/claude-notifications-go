# Deep Architecture Analysis: claude-notifications-go

> Generated: 2026-02-27 | Version analyzed: 1.26.0

## Executive Summary

`claude-notifications-go` is a Claude Code plugin written in Go that delivers intelligent desktop notifications and webhook alerts when Claude Code completes tasks, asks questions, creates plans, or encounters errors. It replaces an earlier Bash implementation and is designed around three hard problems:

1. **Claude Code fires hooks 2-4x per event** (bug #9602) — requiring a distributed deduplication system
2. **The binary is short-lived** (one process per hook invocation) — requiring file-system-based state persistence
3. **Click-to-focus must work across 14+ terminal emulators, 4 multiplexers, and 3 OSes** — requiring deep platform integration via CGO, Objective-C, D-Bus, and AppleScript

The codebase is ~82 Go source files, ~15 Swift files, ~7 shell scripts, and supports macOS (Intel + Apple Silicon), Linux (x64 + ARM64), and Windows (x64).

---

## 1. System Context

```
                                 ┌──────────────────────────┐
                                 │     Claude Code CLI      │
                                 │  (fires hook events via  │
                                 │   hooks.json contract)   │
                                 └────────────┬─────────────┘
                                              │ stdin: JSON
                                              │ {session_id, transcript_path, cwd, tool_name}
                                              ▼
                                 ┌──────────────────────────┐
                                 │    bin/hook-wrapper.sh    │
                                 │  - version check         │
                                 │  - auto-update binary    │
                                 │  - set CLAUDE_PLUGIN_ROOT│
                                 └────────────┬─────────────┘
                                              │
                                              ▼
                              ┌─────────────────────────────────┐
                              │  claude-notifications binary    │
                              │  cmd/claude-notifications/main.go│
                              └──────────────┬──────────────────┘
                                             │
                    ┌────────────────────────┼──────────────────────┐
                    ▼                        ▼                      ▼
           ┌──────────────┐        ┌─────────────────┐    ┌──────────────┐
           │ handle-hook  │        │  focus-window    │    │   daemon     │
           │ (primary)    │        │  (macOS CGO)     │    │ (Linux only) │
           └──────┬───────┘        └─────────────────┘    └──────────────┘
                  │
    ┌─────────────┼──────────────────────────────────┐
    ▼             ▼             ▼                      ▼
┌────────┐  ┌─────────┐  ┌──────────┐          ┌──────────┐
│ Desktop│  │  Sound   │  │ Webhook  │          │ Terminal │
│ Notify │  │ Playback │  │  HTTP    │          │   Bell   │
└────────┘  └──────────┘  └──────────┘          └──────────┘
```

---

## 2. Package Dependency Graph

```
cmd/claude-notifications/main.go
    │
    ├── internal/errorhandler    (panic recovery, SafeGo)
    ├── internal/logging         (file logger)
    ├── internal/hooks           (orchestration layer)
    │       │
    │       ├── internal/config          (JSON config, migration, defaults)
    │       ├── internal/dedup           (two-phase file-lock dedup)
    │       ├── internal/state           (session persistence, cooldowns)
    │       ├── internal/analyzer        (status state machine)
    │       │       └── pkg/jsonl        (JSONL streaming parser)
    │       ├── internal/summary         (message generation, markdown cleanup)
    │       │       └── pkg/jsonl
    │       ├── internal/notifier        (desktop notifications)
    │       │       ├── internal/audio   (malgo/miniaudio playback)
    │       │       ├── internal/sounds  (sound file discovery)
    │       │       ├── internal/sessionname (friendly session names)
    │       │       └── internal/daemon  (Linux D-Bus IPC, focus)
    │       ├── internal/webhook         (HTTP with retry/circuit-breaker/rate-limit)
    │       └── internal/platform        (OS utils, atomic file ops, git)
    │
    └── internal/notifier                (for focus-window subcommand)
```

Key observation: `internal/hooks` is the **single orchestration layer** — it owns the complete notification pipeline. Every other package is a leaf dependency with no back-references, making the dependency graph a clean tree.

---

## 3. Hook System: The Plugin Contract

### 3.1 Hook Registration

Claude Code discovers hooks through `hooks/hooks.json`:

| Hook Event | Matcher | When Fired |
|---|---|---|
| `PreToolUse` | `ExitPlanMode\|AskUserQuestion` | Before Claude executes ExitPlanMode or AskUserQuestion |
| `Notification` | `permission_prompt` | When Claude needs user permission for a tool |
| `Stop` | *(none — all stops)* | When Claude finishes responding |
| `SubagentStop` | *(none)* | When a Task subagent finishes |

### 3.2 Data Contract

Claude Code writes JSON to the hook process's stdin:

```json
{
  "session_id": "73b5e210-ec1a-4f8b-...",
  "transcript_path": "/Users/x/.claude/projects/.../session.jsonl",
  "cwd": "/Users/x/my-project",
  "tool_name": "ExitPlanMode",
  "hook_event_name": "PreToolUse"
}
```

The binary reads this exactly once from stdin, processes it, sends notifications, and exits. There is no long-running process (except the Linux daemon for click-to-focus callbacks).

### 3.3 Hook Wrapper: Lazy Binary Management

`bin/hook-wrapper.sh` is the actual command registered in hooks.json. It provides:

1. **Platform detection** — determines the correct binary suffix (darwin-arm64, linux-amd64, etc.)
2. **Version checking** — compares `binary version` output against `plugin.json` version
3. **Auto-update** — runs `install.sh --force` if versions mismatch (silent, with systemMessage feedback)
4. **Git text-symlink handling** — detects when Git creates symlinks as text stubs (Windows/some configs) and falls back to the platform-specific binary directly
5. **Environment setup** — sets `CLAUDE_PLUGIN_ROOT` before invoking the binary

This means the binary is guaranteed to match the plugin version on every invocation, even after plugin updates via the marketplace.

---

## 4. Core Pipeline: HandleHook()

The heart of the system is `internal/hooks/hooks.go → HandleHook()`. Here is the complete pipeline with every decision point:

```
HandleHook(hookEvent, stdin)
│
├─ [GUARD 1] CLAUDE_HOOK_JUDGE_MODE=true → EXIT
│   (Suppresses notifications from background AI judge processes)
│
├─ json.Decode(stdin) → HookData{session_id, transcript_path, cwd, tool_name}
│
├─ [GUARD 2] dedupMgr.CheckEarlyDuplicate(sessionID, hookEvent)
│   → Check if lock file exists AND age < 2 seconds → EXIT if duplicate
│
├─ [GUARD 3] cfg.IsAnyNotificationEnabled() → EXIT if all disabled
│
├─ [STATUS DETERMINATION]
│   switch hookEvent:
│     "PreToolUse"    → analyzer.GetStatusForPreToolUse(toolName)
│     "Notification"  → StatusQuestion (always)
│     "SubagentStop"  → check cfg.SuppressForSubagents → handleStopEvent()
│     "Stop"          → handleStopEvent()
│                        └─ analyzer.AnalyzeTranscript(transcriptPath, cfg)
│
├─ [GUARD 4] status == StatusUnknown → EXIT
│
├─ [GUARD 5] dedupMgr.AcquireLock(sessionID, hookEvent)
│   → Atomic O_EXCL file creation → EXIT if another process won the race
│
├─ [GUARD 6] Question cooldown checks (if status == question):
│   ├─ stateMgr.ShouldSuppressQuestionAfterAnyNotification(sessionID, cooldownSecs)
│   └─ stateMgr.ShouldSuppressQuestion(sessionID, cooldownSecs)
│       → EXIT if within cooldown window
│
├─ [STATE UPDATE] stateMgr.UpdateTaskComplete(sessionID) (if task_complete)
│
├─ [MESSAGE GENERATION]
│   └─ summary.GenerateFromTranscript(transcriptPath, status)
│      + actions string: "📝 3 new  ✏️ 2 edited  ▶ 1 cmds  ⏱ 2m 15s"
│
├─ [GUARD 7] dedupMgr.AcquireContentLock(sessionID)
│   → 5-second TTL lock prevents Stop+Notification race
│
├─ [GUARD 8] stateMgr.IsDuplicateMessage(sessionID, message, 180s)
│   → Normalized content comparison within 3-minute window → EXIT if duplicate
│
├─ [STATE UPDATE] stateMgr.UpdateLastNotification(sessionID, status, message)
│
└─ sendNotifications(status, message, sessionID, cwd)
    ├─ sessionname.GenerateSessionLabel(sessionID) → "peak 73b5e210"
    ├─ platform.GetGitBranch(cwd) → "main"
    ├─ filepath.Base(cwd) → "my-project"
    ├─ enhancedMessage = "[peak|main my-project] message"
    │
    ├─ [DESKTOP] if cfg.IsStatusDesktopEnabled(status):
    │   notifierSvc.SendDesktop(status, enhancedMessage, sessionID, cwd)
    │
    └─ [WEBHOOK] if cfg.IsStatusWebhookEnabled(status):
        webhookSvc.SendAsync(status, enhancedMessage, sessionID)
```

**8 guard clauses** before any notification is sent. This defensive architecture ensures no false or duplicate notifications escape.

---

## 5. Status Detection: The Analyzer State Machine

`internal/analyzer/analyzer.go` implements a priority-ordered status classifier that reads Claude's JSONL transcript.

### 5.1 Tool Categories

```go
ActiveTools   = {"Write", "Edit", "Bash", "NotebookEdit", "SlashCommand", "KillShell"}
QuestionTools = {"AskUserQuestion"}
PlanningTools = {"ExitPlanMode", "TodoWrite"}
PassiveTools  = {"Read", "Grep", "Glob", "WebFetch", "WebSearch", "Search", "Fetch", "Task"}
```

### 5.2 Decision Priority

```
1. [HIGHEST] Session limit text detected in last 3 messages
   → StatusSessionLimitReached

2. isApiErrorMessage flag in JSONL entries
   → error == "authentication_failed" → StatusAPIError
   → otherwise → StatusAPIErrorOverloaded

3. Filter to messages after last user timestamp (temporal isolation)
   Take last 15 assistant messages (bounded window)
   Extract all tool_use blocks

4. If tools found:
   a. Last tool == ExitPlanMode → StatusPlanReady
   b. Last tool == AskUserQuestion → StatusQuestion
   c. ExitPlanMode present AND other tools follow → StatusTaskComplete
   d. Only passive tools (Read/Grep/Glob) AND >200 chars text → StatusReviewComplete
   e. Last tool in ActiveTools → StatusTaskComplete
   f. Any tool at all → StatusTaskComplete (fallback)

5. [LOWEST] No tools:
   → cfg.ShouldNotifyOnTextResponse() → StatusTaskComplete
   → otherwise → StatusUnknown (no notification)
```

### 5.3 Temporal Isolation

A critical design feature: `FilterMessagesAfterTimestamp()` ensures only the **current response's** tools are analyzed. Without this, a leftover `ExitPlanMode` from a previous interaction would produce a false `plan_ready` status on every subsequent Stop event.

### 5.4 The 15-Message Window

The analyzer takes the last 15 messages after the user timestamp. This bounds both memory usage and analysis scope, preventing ancient transcript history from affecting current status detection.

---

## 6. Deduplication: Solving the Double-Fire Bug

Claude Code bug #9602 causes hooks to fire 2-4 times for a single event. The dedup system in `internal/dedup/dedup.go` uses a **two-phase file-system lock** to solve this across concurrent processes.

### 6.1 Why Not a Mutex?

Each hook invocation spawns a separate OS process. In-process mutexes cannot coordinate across processes. The file system is the only shared state available.

### 6.2 Lock File Design

| Lock Type | File Pattern | TTL | Purpose |
|---|---|---|---|
| Per-hook | `claude-notification-{session}-{hook}.lock` | 2s | Dedup same hook event |
| Content | `claude-notification-{session}-content.lock` | 5s | Prevent Stop+Notification race |

Lock files live in `$TMPDIR`. They are **never explicitly released** — they age out naturally. This is deliberate: if the process crashes after creating the lock, the lock expires in 2 seconds rather than being permanently held.

### 6.3 The Two Phases

**Phase 1: Early Check (read-only, no side effects)**
```
if lock_file_exists AND file_age < 2 seconds:
    → this is a duplicate, EXIT immediately
```
This catches 95%+ of duplicates with zero I/O overhead (just a stat call).

**Phase 2: Atomic Acquisition (after status analysis, before sending)**
```
try O_CREATE|O_EXCL → atomic file creation
if created:
    → we won the race, PROCEED to send
if already exists AND age < 2s:
    → another process won, EXIT
if already exists AND age >= 2s:
    → stale lock from previous event, remove and retry
```

### 6.4 Why Phase 2 is After Analysis

The lock is acquired **after** status analysis but **before** sending. This prevents "0 notifications" when an early process creates the lock and then exits due to `StatusUnknown` (which would prevent any process from sending).

### 6.5 Content Lock

A separate content lock with 5-second TTL prevents the race between `Stop` and `Notification` hooks firing simultaneously for the same session. Both hooks might produce `StatusQuestion` — the content lock ensures only one sends.

---

## 7. Desktop Notification Delivery

`internal/notifier/notifier.go` implements a multi-strategy notification dispatcher.

### 7.1 Strategy Selection

```
SendDesktop(status, message, sessionID, cwd)
│
├─ ALWAYS: sendTerminalBell()
│   → write "\a" (BEL character) to /dev/tty
│   → triggers tmux bell indicator, Ghostty tab highlight
│
├─ [macOS + ClickToFocus + terminal-notifier available]:
│   sendWithTerminalNotifier()
│   → rich notifications with click-to-focus callback
│
├─ [Linux + ClickToFocus]:
│   sendLinuxNotification() → sendViaDaemon()
│   → D-Bus notifications with action callbacks via daemon
│
└─ [Fallback / Windows / no click-to-focus]:
    sendWithBeeep()
    → cross-platform notifications via beeep library
```

### 7.2 macOS Click-to-Focus Architecture

On macOS, `terminal-notifier` (or `ClaudeNotifier.app`) displays the notification. The `-execute` flag specifies a shell command to run when the user clicks:

```
For multiplexers (detected first):
  tmux  → tmux -S /tmp/tmux-501/default select-window -t %42 ; select-pane -t %42
  zellij → zellij -s mysession action go-to-tab-name mytab
  wezterm → wezterm cli activate-pane --pane-id 42
  kitty  → kitten @ --to unix:/tmp/kitty focus-window --match id:42

For standalone terminals:
  Ghostty → claude-notifications focus-window com.mitchellh.ghostty /path/to/cwd
  VS Code → claude-notifications focus-window com.microsoft.VSCode /path/to/cwd
  Other   → osascript -e 'tell app "Terminal" to activate'
```

### 7.3 macOS Window Focus via CGO

`internal/notifier/ax_focus_darwin.go` uses CGO with Objective-C to call macOS Accessibility and CoreGraphics APIs:

```objc
// Links: ApplicationServices, AppKit, CoreGraphics
// Uses private CGS API for Space switching

For Ghostty (OSC 7 CWD URL):
  1. activateApp(pid) → NSRunningApplication.activate
  2. raiseWindowByAXDocument(pid, fileURL)
     → AXUIElementCreateApplication(pid)
     → iterate AXWindows
     → match AXDocument attribute against file:///path/to/cwd
     → AXUIElementPerformAction(kAXRaiseAction)

For VS Code / generic:
  1. findSwitchAndActivate(pid, folderName)
     → CGSGetOnScreenWindowList → find window ID by title substring
     → CGSGetWindowWorkspace → get Space ID
     → CGSSetWorkspace → switch to that Space
     → NSRunningApplication.activate
  2. raiseWindowByAXTitle(pid, folderName)
     → iterate AXWindows → match AXTitle against folder name
     → AXUIElementPerformAction(kAXRaiseAction)
```

This is necessary because macOS has no simple API to "focus a specific window of an app on a specific Space." The code uses the private CGS (Core Graphics Server) API to switch Spaces, then the public Accessibility API to raise the correct window.

### 7.4 Linux Click-to-Focus: The Daemon

Linux desktop notifications via D-Bus are inherently asynchronous — when the user clicks a notification, the callback is sent to the D-Bus connection that created it. Since the main binary exits immediately, a background daemon maintains the connection.

```
sendLinuxNotification()
│
├─ daemon.StartDaemonOnDemand()
│   ├─ IsDaemonRunning() → ping Unix socket
│   └─ if not running:
│       exec.Command(binary, "--daemon") with Setsid (new session)
│       poll IsDaemonRunning() up to 5 seconds
│
├─ daemon.NewClient() → connect to Unix socket
│
└─ client.SendNotification(title, body, "", folderName, 30)
    → JSON-over-Unix-socket → daemon receives
    → daemon.handleNotification()
        ├─ esiqveland/notify.SendNotification() → D-Bus → freedesktop notifications
        ├─ store focusCtx[notificationID] = {terminal, folder}
        └─ onActionInvoked(notificationID) → TryFocus(terminal, folder)
```

The daemon auto-shuts down after 5 minutes of inactivity to avoid resource waste.

Linux focus uses a fallback chain of 7 methods:
1. `activate-window-by-title` GNOME extension (preferred)
2. GNOME Shell Eval by window title
3. GNOME Shell Eval by app
4. GNOME Shell FocusApp (GNOME 45+)
5. `wlrctl` (Sway/wlroots compositors)
6. `kdotool` (KDE Plasma)
7. `xdotool` (X11: XFCE, MATE, Cinnamon, i3)

---

## 8. Audio Subsystem

`internal/audio/audio.go` provides cross-platform audio playback via miniaudio (C library) through CGO.

### 8.1 Architecture

```go
type Player struct {
    ctx        *malgo.AllocatedContext  // miniaudio context (C)
    deviceID   *malgo.DeviceID          // nil = system default
    volume     float64                  // 0.0-1.0
    mu         sync.Mutex               // guards concurrent Play() calls
}
```

### 8.2 Playback Pipeline

```
Play(soundPath)
│
├─ Open file, detect format by extension
│
├─ Decode to raw PCM:
│   .mp3  → gopxl/beep/mp3.Decode()
│   .wav  → gopxl/beep/wav.Decode()
│   .flac → gopxl/beep/flac.Decode()
│   .ogg  → gopxl/beep/vorbis.Decode()
│   .aiff → go-audio/aiff.NewDecoder()
│
├─ Apply volume: samples[i] = int16(float64(samples[i]) * volume)
│
├─ Convert to little-endian bytes
│
├─ Initialize malgo device:
│   Format: S16 (signed 16-bit)
│   PeriodSize: 4096 frames
│   Periods: 4 buffers
│
├─ Start device, stream bytes via dataCallback
│
└─ Wait for completion (done channel) + 200ms drain delay
    → 30-second hard timeout as safety net
```

### 8.3 Design Decisions

- **Lazy initialization via sync.Once**: Audio context creation involves CGO and is expensive (~50ms). Initialized only on first sound, then reused for all subsequent sounds.
- **4096-frame period with 4 buffers**: Prevents audio crackling by providing enough buffer depth. Smaller periods cause underruns.
- **200ms drain delay**: Prevents the last few milliseconds of audio from being cut off when the device is stopped.
- **Volume applied in software**: Rather than using OS volume controls, volume is applied by scaling PCM samples directly. This works identically across all platforms.

---

## 9. Webhook Subsystem

`internal/webhook/webhook.go` implements a production-grade HTTP webhook sender with three resilience patterns.

### 9.1 Architecture

```
Sender
├── *http.Client (10s timeout)
├── *Retryer
│   └── Exponential backoff: base * 2^(attempt-1) + jitter
│       Initial: 1s, Max: 10s, Max attempts: 3
│       4xx errors (except 429) → NOT retried
├── *CircuitBreaker
│   └── States: Closed → Open → HalfOpen → Closed
│       Open after: 5 consecutive failures
│       Reset timeout: 30 seconds
│       Close after: 2 successes in HalfOpen
├── *RateLimiter
│   └── Token bucket: 10 requests/minute
│       Refill rate: 10/60 tokens/second
└── *Metrics
    └── Atomic counters: total, success, failure, per-status
        Latency tracking per request
```

### 9.2 Send Flow

```
SendAsync(status, message, sessionID)
│
├─ [goroutine via SafeGo, tracked by WaitGroup]
│
├─ rateLimiter.Allow() → drop if exceeded
│
├─ circuitBreaker.GetState() == Open → fail fast
│
├─ Format payload by preset:
│   "slack"    → {"attachments": [{"color":"#28a745", "title":"...", ...}]}
│   "discord"  → {"embeds": [{"color":2664261, "title":"...", ...}]}
│   "telegram" → {"chat_id":"...", "text":"<b>...</b>", "parse_mode":"HTML"}
│   "lark"     → {"msg_type":"interactive", "card":{...}}
│   "custom"   → JSON or plain text
│
├─ circuitBreaker.Execute(func() error {
│       return retry.Do(func() error {
│           return sendHTTPRequest(url, payload, headers)
│       })
│   })
│
└─ metrics.RecordSuccess() or metrics.RecordFailure()
```

### 9.3 Graceful Shutdown

`HandleHook()` defers `webhookSvc.Shutdown(5*time.Second)` which calls `cancel()` on the context and waits for the WaitGroup with a timeout. This ensures in-flight webhooks complete before the process exits — a deliberate fix for Issue #6 where webhooks were silently dropped.

---

## 10. Configuration System

`internal/config/config.go` implements a 3-level config loading chain with automatic migration.

### 10.1 Loading Precedence

```
1. ~/.claude/claude-notifications-go/config.json   (STABLE — survives plugin updates)
2. <pluginRoot>/config/config.json                  (LEGACY — auto-migrated)
3. DefaultConfig()                                  (built-in defaults)
```

### 10.2 Auto-Migration

When config exists at the legacy path but not the stable path, `migrateConfig()` copies it atomically:
```
1. Write to temp file in same directory as target
2. os.Rename(temp, target)  → atomic on same filesystem
```

### 10.3 Key Configuration Surface

```
notifications.desktop.enabled         # global desktop on/off
notifications.desktop.sound           # play audio sounds
notifications.desktop.terminalBell    # BEL character to /dev/tty (default: true)
notifications.desktop.volume          # 0.0-1.0 (default: 1.0)
notifications.desktop.audioDevice     # specific device name or "" for default
notifications.desktop.clickToFocus    # activate terminal window on click
notifications.desktop.terminalBundleID # override macOS bundle ID detection

notifications.webhook.enabled         # global webhook on/off
notifications.webhook.preset          # "slack"|"discord"|"telegram"|"lark"|"custom"
notifications.webhook.url             # webhook endpoint
notifications.webhook.chatID          # Telegram chat ID
notifications.webhook.retry           # {maxAttempts, initialBackoff, maxBackoff}
notifications.webhook.circuitBreaker  # {failureThreshold, successThreshold, timeout}
notifications.webhook.rateLimit       # {requestsPerMinute}

notifications.suppressQuestionAfterTaskCompleteSeconds    # default: 12
notifications.suppressQuestionAfterAnyNotificationSeconds # default: 0 (disabled)
notifications.suppressForSubagents                        # default: true
notifications.notifyOnTextResponse                        # default: true
notifications.respectJudgeMode                            # default: true

statuses.<status>.enabled   # per-status enable/disable
statuses.<status>.title     # custom notification title
statuses.<status>.sound     # custom sound file path
```

---

## 11. State Management

`internal/state/state.go` persists per-session state as JSON files in `$TMPDIR`.

### 11.1 State File

Path: `$TMPDIR/claude-session-state-{sessionID}.json`

```json
{
  "session_id": "73b5e210-ec1a-...",
  "last_interactive_tool": "ExitPlanMode",
  "last_ts": 1709000000,
  "last_task_complete_ts": 1709000000,
  "last_notification_ts": 1709000005,
  "last_notification_status": "task_complete",
  "last_notification_message": "Created factorial function",
  "cwd": "/Users/x/my-project"
}
```

### 11.2 Cooldown Logic

Two independent cooldown timers suppress rapid question notifications:

**Timer 1: After task completion** (`suppressQuestionAfterTaskCompleteSeconds`, default: 12s)
```
If status == question AND (now - last_task_complete_ts) < 12 seconds:
    → suppress the question notification
```
This prevents the common pattern where Stop fires (task_complete), then immediately a Notification fires (question for permission_prompt) for the same interaction.

**Timer 2: After any notification** (`suppressQuestionAfterAnyNotificationSeconds`, default: 0)
```
If status == question AND (now - last_notification_ts) < N seconds:
    → suppress the question notification
```
Disabled by default (0). When set, prevents question spam in rapid-fire interactions.

### 11.3 Content-Based Dedup

```
IsDuplicateMessage(sessionID, message, windowSecs=180):
    normalize(message) == normalize(lastMessage) AND elapsed < 180 seconds
    → duplicate
```

`normalize()` trims whitespace, trailing dots, and lowercases. This catches identical Stop+Notification races that pass the file-lock dedup (because they're different hook events with different lock files).

---

## 12. Message Generation

`internal/summary/summary.go` generates human-readable notification bodies from Claude's JSONL transcript.

### 12.1 Per-Status Strategy

| Status | Strategy |
|---|---|
| `question` | Extract `AskUserQuestion` tool text → find text with "?" → first sentence |
| `plan_ready` | Extract `ExitPlanMode` tool `plan` input → first non-empty line |
| `review_complete` | Count Read tools → look for review keywords → "Code review completed" |
| `task_complete` | Last assistant text → clean markdown → first sentence if >= 150 chars |
| `session_limit_reached` | Static: "Session limit reached. Please start a new conversation." |
| `api_error` | Static: "Please run /login" |
| `api_error_overloaded` | Extract actual error text from API error message |

### 12.2 Actions String

Appended to all messages:
```
📝 3 new  ✏️ 2 edited  ▶ 1 cmds  ⏱ 2m 15s
```
Counts Write/Edit/Bash tools used since the last user message, plus the elapsed time.

### 12.3 Markdown Cleaning

`CleanMarkdown()` strips: code blocks, images (keeps alt text), links (keeps text), bold, italic, strikethrough, backticks, headers, blockquotes, bullets. Then normalizes whitespace to single spaces.

### 12.4 Text Truncation

Intelligent truncation to 150 characters:
1. Find first sentence boundary (`. `, `! `, `? `) within limit
2. If no sentence: find last word boundary (space)
3. If no word boundary: hard cut at limit-3 + `"..."`

---

## 13. Session Name Generation

`internal/sessionname/sessionname.go` generates deterministic friendly labels from session UUIDs:

```
"73b5e210-ec1a-..." → hex seed "73b5e210" → index 46 → "peak"
```

35 adjectives + 35 nouns = 70-word vocabulary. Label: `"peak 73b5e210"`.
This appears in notification titles: `"✅ Completed [peak]"` and in the message body: `"[peak|main my-project] ..."`.

---

## 14. Error Handling Architecture

`internal/errorhandler/errorhandler.go` implements a singleton error handler with panic recovery.

### 14.1 Panic Recovery Points

```
main()
└─ defer errorhandler.HandlePanic()
    └─ handleHook()
        └─ defer errorhandler.HandlePanic()
            ├─ sendNotifications()
            │   └─ defer errorhandler.HandlePanic()
            ├─ playSoundAsync() goroutine → SafeGo()
            └─ SendAsync() goroutine → SafeGo()
```

Every goroutine uses `SafeGo(fn)` which wraps `fn` in `WithRecovery()`. A panic in a sound goroutine doesn't kill the webhook goroutine or vice versa.

### 14.2 Error Classification

- `HandleError()` — logged, non-fatal, execution continues
- `HandleCriticalError()` — logged + stderr, may call `os.Exit(1)` if `exitOnCritical`
- `HandlePanic()` — `recover()` + full stack trace + log

The binary is initialized with `Init(logToConsole=true, exitOnCritical=false, recoveryEnabled=true)` — it logs everything but never exits on errors, preferring to degrade gracefully (e.g., skip sound if audio init fails, skip webhook if network is down).

---

## 15. JSONL Parser

`pkg/jsonl/jsonl.go` is the only public package. It parses Claude Code's streaming JSONL transcript format.

### 15.1 Message Types

```go
type Message struct {
    Type              string         // "user" | "assistant"
    Message           MessageContent // polymorphic content
    Timestamp         string         // RFC3339
    IsApiErrorMessage bool           // API error flag
    Error             string         // e.g. "authentication_failed"
    ParentUUID        string         // conversation threading
}

type MessageContent struct {
    Role          string    // "user" | "assistant"
    Content       []Content // structured: tool_use, tool_result, text blocks
    ContentString string    // unstructured: user text messages
}
```

### 15.2 Polymorphic Deserialization

Custom `UnmarshalJSON` on `MessageContent` handles Claude Code's dual format:
- User messages: `"message": {"role":"user","content":"hello"}` (content is a string)
- Assistant messages: `"message": {"role":"assistant","content":[{"type":"text",...}]}` (content is an array)

### 15.3 Key Query Functions

| Function | Purpose |
|---|---|
| `ParseFile(path)` | Parse entire JSONL file into `[]Message` |
| `GetLastUserTimestamp(messages)` | Find the last user message's timestamp |
| `FilterMessagesAfterTimestamp(messages, ts)` | Temporal isolation |
| `ExtractTools(messages)` | Extract all `tool_use` blocks with positions |
| `GetLastTool(tools)` | Most recent tool |
| `ExtractRecentText(messages, maxLen)` | Last assistant text content |
| `HasRecentApiError(messages)` | Check for API error flags |

---

## 16. Build & Release System

### 16.1 Why Native Runners, Not Cross-Compilation

The project requires CGO for `github.com/gen2brain/malgo` (miniaudio C bindings). Cross-compiling CGO is notoriously difficult, especially for macOS (requires macOS SDK). The release workflow uses **native runners** for each platform:

| Platform | Runner | Binary |
|---|---|---|
| macOS Intel | `macos-15` | `claude-notifications-darwin-amd64` |
| macOS ARM | `macos-latest` | `claude-notifications-darwin-arm64` |
| Linux x64 | `ubuntu-latest` | `claude-notifications-linux-amd64` |
| Linux ARM64 | `ubuntu-24.04-arm` | `claude-notifications-linux-arm64` |
| Windows x64 | `windows-latest` | `claude-notifications-windows-amd64.exe` |

Each platform also builds 3 utility binaries: `sound-preview`, `list-devices`, `list-sounds`.

### 16.2 Release Pipeline

```
git tag v1.26.0 && git push --tags
│
├─ build-matrix (5 parallel jobs, native runners)
│   └─ CGO_ENABLED=1 go build -ldflags="-s -w" -trimpath
│      → uploads platform artifacts
│
├─ build-notifier (macOS only, parallel)
│   └─ swift build + ditto -c -k → ClaudeNotifier.app.zip
│
├─ create-release (depends on both above)
│   └─ download all artifacts
│   └─ sha256sum * > checksums.txt
│   └─ softprops/action-gh-release → GitHub Release
│
└─ test-binaries (depends on release)
    └─ download from release, run --version on each platform
```

### 16.3 Binary Distribution

Users get the binary through three paths:
1. **`/init` command** — downloads `install.sh` from GitHub, which downloads the binary
2. **`bootstrap.sh`** — one-command curl-pipe-bash installer
3. **`hook-wrapper.sh`** — auto-downloads/updates on first hook invocation

All paths converge on `install.sh` which:
- Detects platform and architecture
- Downloads from GitHub Releases
- Verifies SHA256 checksum
- Checks binary size (>1MB) and execution (`--version`)
- Creates symlinks for cross-platform naming

---

## 17. Testing Strategy

### 17.1 Test Layers

| Layer | Files | Pattern |
|---|---|---|
| Unit tests | ~40 `*_test.go` files | Table-driven, `t.TempDir()`, mock interfaces |
| Integration tests | `hooks/integration_test.go` | Build tag `integration`, mock notifier/webhook |
| E2E (Go) | `tmux_e2e_test.go`, `zellij_e2e_test.go` | Real multiplexer processes |
| E2E (Shell) | `install_e2e_test.sh` | Mock HTTP server, real binary execution |
| CI Matrix | 3 workflows | Go 1.21 + 1.22, macOS + Ubuntu + Windows |

### 17.2 Mock Design

The `Handler` struct uses interfaces for its two output channels:

```go
type notifierInterface interface {
    SendDesktop(status, message, sessionID, cwd string) error
    Close()
}

type webhookInterface interface {
    SendAsync(status, message, sessionID string)
    Shutdown(timeout time.Duration)
}
```

Tests inject `mockNotifier` and `mockWebhook` with mutex-protected call logs, enabling assertions like:

```go
assert.Equal(t, 1, len(mockNotifier.calls))
assert.Equal(t, "task_complete", mockNotifier.calls[0].status)
```

### 17.3 Shell Test Infrastructure

`bin/mock_server.py` is a Python HTTP server with controllable failure modes:

| URL Pattern | Behavior |
|---|---|
| `/404/*` | 404 Not Found |
| `/500/*` | 500 Server Error |
| `/slow/*` | 120-second delay |
| `/fail-then-ok/*` | Fails first 2 requests, succeeds on 3rd |
| `/wrong-checksum` | Serves content with mismatched checksum |
| `/corrupted.zip` | Invalid ZIP header |
| `/small-file` | Tiny file (fails size validation) |

The E2E tests create 2MB padded fake binaries with computed SHA256 checksums, served through the mock server to test the full install flow.

---

## 18. Cross-Cutting Concerns

### 18.1 Concurrency Safety

| Resource | Protection |
|---|---|
| Audio playback | `sync.Mutex` on Player |
| Sound goroutines | `sync.WaitGroup` + `closing` flag |
| Webhook goroutines | `sync.WaitGroup` + `context.Context` |
| Logger initialization | `sync.Once` |
| Audio player initialization | `sync.Once` |
| Circuit breaker state | `sync.Mutex` |
| Rate limiter tokens | `sync.Mutex` |
| Metrics counters | `atomic.Int64` |

### 18.2 Process Lifecycle

```
Process start
├── errorhandler.Init() — set up panic recovery
├── logging.InitLogger() — open log file
├── hooks.NewHandler() — load config, create all services
│
├── handler.HandleHook() — run pipeline (blocking)
│   ├── dedup checks
│   ├── analyze transcript
│   ├── send desktop notification (may spawn sound goroutine)
│   └── send webhook (spawns HTTP goroutine)
│
├── defer notifierSvc.Close() — wait for sound goroutines
├── defer webhookSvc.Shutdown(5s) — wait for HTTP goroutines
└── exit
```

Total process lifetime: typically 50-500ms depending on transcript size and notification method.

### 18.3 File System Usage

| Path | Purpose | Lifetime |
|---|---|---|
| `$TMPDIR/claude-notification-*-*.lock` | Dedup locks | 2s TTL (ages out) |
| `$TMPDIR/claude-notification-*-content.lock` | Content race lock | 5s TTL |
| `$TMPDIR/claude-session-state-*.json` | Session state | Cleaned after 60s |
| `~/.claude/claude-notifications-go/config.json` | User config | Permanent |
| `<pluginRoot>/notification-debug.log` | Debug log | Grows indefinitely |
| `/dev/tty` | Terminal bell | Written once per notification |

---

## 19. Key Architectural Trade-offs

### 19.1 Short-lived process vs. long-running daemon

**Choice**: Short-lived process (except Linux daemon for D-Bus callbacks)

**Why**: Claude Code hooks expect the process to exit quickly. A daemon would need IPC, health monitoring, and restart logic. The short-lived approach is simpler and more reliable — if it crashes, the next hook invocation starts fresh.

**Cost**: State must be persisted to the file system between invocations (~2-5ms overhead per state read/write).

### 19.2 File-system locks vs. process-based coordination

**Choice**: File-system locks with TTL aging

**Why**: Each hook invocation is a separate process. No shared memory is available. The file system is the only coordination mechanism that works across processes.

**Cost**: Small race window (~1-2% chance of duplicate notification). Acceptable because duplicate notifications are merely annoying, while missing notifications are unacceptable.

### 19.3 CGO dependency for audio

**Choice**: `malgo` (miniaudio C bindings via CGO)

**Why**: Pure-Go audio libraries either don't support all platforms or have quality issues (crackling, latency). miniaudio is battle-tested C code used in game engines.

**Cost**: Cannot cross-compile — requires native runners for each platform in CI. Binary size is larger. Build requires C compiler on every target platform.

### 19.4 CGO for macOS window focus

**Choice**: Objective-C via CGO for Accessibility API and private CGS API

**Why**: No Go bindings exist for macOS Accessibility API. AppleScript alone cannot switch Spaces or focus specific windows by CWD path. The private CGS API is the only way to switch Spaces programmatically.

**Cost**: Couples to undocumented Apple APIs that may break in future macOS versions. Requires careful error handling for permission denials.

### 19.5 Shell wrapper instead of direct binary invocation

**Choice**: `hook-wrapper.sh` wraps the binary

**Why**: Enables version checking and auto-update on every invocation. The binary can be updated without re-registering hooks. The wrapper also handles Git text-symlink edge cases on Windows.

**Cost**: ~50-100ms shell startup overhead per hook invocation. Acceptable given the total 50-500ms process lifetime.
