# Implementation Deep Dive: claude-notifications-go

> Generated: 2026-02-27 | Version analyzed: 1.26.0

This document provides line-level implementation details for every major component, covering code patterns, edge cases, and the reasoning behind non-obvious decisions.

---

## Table of Contents

1. [Entry Point & Command Dispatch](#1-entry-point--command-dispatch)
2. [Hook Handler: The Orchestration Layer](#2-hook-handler-the-orchestration-layer)
3. [JSONL Parser: Polymorphic Deserialization](#3-jsonl-parser-polymorphic-deserialization)
4. [Analyzer: Status State Machine Edge Cases](#4-analyzer-status-state-machine-edge-cases)
5. [Deduplication: Atomic File Locking](#5-deduplication-atomic-file-locking)
6. [State Manager: Cooldown Arithmetic](#6-state-manager-cooldown-arithmetic)
7. [Summary Generator: Text Extraction Heuristics](#7-summary-generator-text-extraction-heuristics)
8. [Notifier: Platform Dispatch Matrix](#8-notifier-platform-dispatch-matrix)
9. [Audio Player: PCM Streaming via CGO](#9-audio-player-pcm-streaming-via-cgo)
10. [Multiplexer Integration: Click-to-Focus Commands](#10-multiplexer-integration-click-to-focus-commands)
11. [macOS Focus: CGO Objective-C Bridge](#11-macos-focus-cgo-objective-c-bridge)
12. [Linux Daemon: D-Bus IPC Protocol](#12-linux-daemon-d-bus-ipc-protocol)
13. [Webhook: Resilience Stack](#13-webhook-resilience-stack)
14. [Configuration: Migration & Validation](#14-configuration-migration--validation)
15. [Error Handler: Panic Recovery Chain](#15-error-handler-panic-recovery-chain)
16. [Shell Infrastructure: hook-wrapper.sh & install.sh](#16-shell-infrastructure)
17. [Swift Notifier: ClaudeNotifier.app](#17-swift-notifier-claudenotifierapp)
18. [Complete File Inventory](#18-complete-file-inventory)

---

## 1. Entry Point & Command Dispatch

**File**: `cmd/claude-notifications/main.go`

```go
const version = "1.26.0"

func main() {
    errorhandler.Init(true, false, true)  // console=true, exitOnCritical=false, recovery=true
    defer errorhandler.HandlePanic()      // outermost panic guard

    if len(os.Args) < 2 { printUsage(); return }

    switch os.Args[1] {
    case "handle-hook":  handleHook(os.Args[2])           // PRIMARY PATH
    case "focus-window": notifier.FocusAppWindow(args...)  // macOS CGO
    case "daemon":       runDaemon()                       // Linux only
    case "version":      fmt.Println(version)
    case "help":         printUsage()
    }
}
```

**`handleHook(hookEvent)`** is the critical path:
1. Resolves `pluginRoot` from `CLAUDE_PLUGIN_ROOT` env var, falling back to the binary's directory parent
2. Initializes the file logger: `logging.InitLogger(pluginRoot)` → writes to `<pluginRoot>/notification-debug.log`
3. Creates the handler: `hooks.NewHandler(pluginRoot)` → loads config, creates all service instances
4. Executes: `handler.HandleHook(hookEvent, os.Stdin)` → reads JSON from stdin, runs the full pipeline

**Platform-specific files**:
- `daemon_linux.go`: `runDaemon()` creates and starts the D-Bus daemon server
- `daemon_other.go`: `runDaemon()` prints "daemon is only supported on Linux" and exits

---

## 2. Hook Handler: The Orchestration Layer

**File**: `internal/hooks/hooks.go`

### Handler Construction

```go
type Handler struct {
    cfg         *config.Config
    dedupMgr    *dedup.Manager
    stateMgr    *state.Manager
    notifierSvc notifierInterface  // interface for testing
    webhookSvc  webhookInterface   // interface for testing
    pluginRoot  string
}
```

`NewHandler(pluginRoot)` loads config via `config.LoadFromPluginRoot(pluginRoot)`, then creates concrete instances. The interfaces enable mock injection in tests — `hooks_test.go` defines `mockNotifier` and `mockWebhook` that record calls.

### HookData Input

```go
type HookData struct {
    SessionID      string `json:"session_id"`
    TranscriptPath string `json:"transcript_path"`
    CWD            string `json:"cwd"`
    ToolName       string `json:"tool_name"`
    HookEventName  string `json:"hook_event_name"`
}
```

### Per-Event Handlers

**`handlePreToolUse(toolName)`**: Calls `analyzer.GetStatusForPreToolUse(toolName)` which is a simple switch: ExitPlanMode → plan_ready, AskUserQuestion → question, else → unknown.

**`handleNotificationEvent()`**: Always returns `StatusQuestion`. The "Notification" hook only fires for `permission_prompt` (the matcher in hooks.json), so it's always a question about whether to allow a tool.

**`handleStopEvent(transcriptPath, cfg)`**: Calls `analyzer.AnalyzeTranscript(transcriptPath, cfg)` — the full state machine analysis of the JSONL transcript.

### SubagentStop Handling

For SubagentStop, two checks are performed:
1. `cfg.ShouldSuppressForSubagents()` → if true (default), skip entirely
2. If not suppressed, check if transcript path contains `/subagents/` as an additional heuristic

### sendNotifications() Details

The message is enhanced with session context:
```
message = "[peak|main my-project] Created factorial function 📝1 ✏️2 ▶1 ⏱45s"
```

The title is constructed per-status with emoji prefix:
```
✅ Completed [peak]
📋 Plan Ready [peak]
❓ Question [peak]
🔍 Review Complete [peak]
⚠️ Session Limit [peak]
🔑 Auth Error [peak]
⚡ API Overloaded [peak]
```

The subtitle (macOS only) shows: `main · my-project` (git branch + folder name).

---

## 3. JSONL Parser: Polymorphic Deserialization

**File**: `pkg/jsonl/jsonl.go`

### The Dual Content Format Problem

Claude Code writes JSONL where user messages have string content and assistant messages have array content:

```jsonl
{"type":"user","message":{"role":"user","content":"Write a function"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here's..."},{"type":"tool_use","name":"Write","input":{...}}]}}
```

### Custom UnmarshalJSON

```go
func (mc *MessageContent) UnmarshalJSON(data []byte) error {
    // Try structured form first (has "content" as array)
    type messageAlias struct {
        Role    string    `json:"role"`
        Content []Content `json:"content"`
    }
    var structured messageAlias
    if err := json.Unmarshal(data, &structured); err == nil && len(structured.Content) > 0 {
        mc.Role = structured.Role
        mc.Content = structured.Content
        return nil
    }

    // Fall back to string form
    type stringAlias struct {
        Role    string `json:"role"`
        Content string `json:"content"`
    }
    var str stringAlias
    if err := json.Unmarshal(data, &str); err == nil {
        mc.Role = str.Role
        mc.ContentString = str.Content
        return nil
    }

    return fmt.Errorf("cannot unmarshal message content")
}
```

### Tool Extraction

`ExtractTools(messages)` iterates all messages, finds `Content` blocks with `Type == "tool_use"`, and returns `[]ToolUse{Position, Name}`. Position is the index in the messages slice, enabling temporal ordering.

### API Error Detection

Two methods:
- `HasRecentApiError(messages)` — checks `IsApiErrorMessage` flag on any message
- `GetLastApiErrorMessages(messages)` — returns actual error text for notification body

---

## 4. Analyzer: Status State Machine Edge Cases

**File**: `internal/analyzer/analyzer.go`

### The "Ghost ExitPlanMode" Problem

Without temporal isolation, an old `ExitPlanMode` from turn 1 would cause every subsequent Stop event to report `plan_ready`. The fix:

```go
userTS := jsonl.GetLastUserTimestamp(messages)
filtered := jsonl.FilterMessagesAfterTimestamp(messages, userTS)
recent := getLastN(filtered, 15)
```

Only messages **after the last user message** are analyzed. This ensures the analyzer sees only the current response.

### The "ExitPlanMode + Implementation" Pattern

A common workflow: Claude exits plan mode, then immediately implements the plan (Write, Edit, Bash). The analyzer handles this:

```go
// ExitPlanMode exists but there are active tools after it
if exitPlanPos >= 0 {
    for _, t := range tools {
        if t.Position > exitPlanPos && isActiveTool(t.Name) {
            return StatusTaskComplete  // not plan_ready!
        }
    }
}
```

### The "Read-Only Response = Review" Heuristic

When Claude only uses passive tools (Read, Grep, Glob) and produces >200 characters of text, it's classified as a review:

```go
if onlyReadLikeTools(tools) && len(extractRecentText(recent)) > 200 {
    return StatusReviewComplete
}
```

The 200-character threshold prevents false positives from short "I'll look at that file" responses.

### Text-Only Response Handling

When Claude responds with text but uses no tools at all:
```go
if len(tools) == 0 {
    if cfg.ShouldNotifyOnTextResponse() {
        return StatusTaskComplete
    }
    return StatusUnknown  // no notification
}
```

The `notifyOnTextResponse` config (default: true) controls this. Users who find text-only notifications noisy can disable it.

---

## 5. Deduplication: Atomic File Locking

**File**: `internal/dedup/dedup.go`

### Atomic File Creation

```go
func AtomicCreateFile(path string) (bool, error) {
    f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
    if err != nil {
        if os.IsExist(err) {
            return false, nil  // file already exists — another process won
        }
        return false, err  // unexpected error
    }
    f.Close()
    return true, nil  // we created it — we won the race
}
```

`O_EXCL` is the key flag: it makes file creation atomic at the kernel level. If two processes race to create the same file, exactly one will succeed and the other will get `EEXIST`.

### Lock Path Construction

```go
func getLockPath(sessionID, hookEvent string) string {
    return filepath.Join(platform.TempDir(), fmt.Sprintf(
        "claude-notification-%s-%s.lock", sessionID, hookEvent))
}
```

Lock files include both session ID and hook event, so `Stop` and `Notification` hooks for the same session get separate locks. The content lock uses a different pattern: `claude-notification-%s-content.lock`.

### Stale Lock Recovery

```go
func AcquireLock(sessionID, hookEvent string) (bool, error) {
    created, err := platform.AtomicCreateFile(lockPath)
    if created { return true, nil }

    // Lock exists — check if stale
    age := platform.FileAge(lockPath)
    if age < 2 { return false, nil }  // fresh lock = duplicate

    // Stale lock (>2s old) — remove and retry
    os.Remove(lockPath)
    return platform.AtomicCreateFile(lockPath)
}
```

The 2-second TTL was chosen empirically: Claude Code's duplicate hooks fire within 50-200ms of each other. A 2-second window catches all duplicates while being short enough to not block legitimate subsequent events.

### Cleanup

After sending notifications, old lock files and state files are cleaned up:
```go
platform.CleanupOldFiles(platform.TempDir(), "claude-notification-*.lock", 60)
platform.CleanupOldFiles(platform.TempDir(), "claude-session-state-*.json", 60)
```

Files older than 60 seconds are removed.

---

## 6. State Manager: Cooldown Arithmetic

**File**: `internal/state/state.go`

### State File I/O

```go
func (m *Manager) loadState(sessionID string) *SessionState {
    path := m.statePath(sessionID)
    data, err := os.ReadFile(path)
    if err != nil { return &SessionState{SessionID: sessionID} }
    var state SessionState
    json.Unmarshal(data, &state)
    return &state
}

func (m *Manager) saveState(state *SessionState) error {
    data, _ := json.MarshalIndent(state, "", "  ")
    return os.WriteFile(m.statePath(state.SessionID), data, 0644)
}
```

No locking is used on state files because each hook invocation runs as a single goroutine that processes sequentially. The dedup system ensures only one process reaches this point per event.

### Cooldown Implementation

```go
func (m *Manager) ShouldSuppressQuestion(sessionID string, cooldownSecs int) bool {
    if cooldownSecs <= 0 { return false }
    state := m.loadState(sessionID)
    if state.LastTaskCompleteTime == 0 { return false }
    elapsed := platform.CurrentTimestamp() - state.LastTaskCompleteTime
    return elapsed < int64(cooldownSecs)
}
```

The 12-second default for `suppressQuestionAfterTaskCompleteSeconds` handles the common sequence:
1. Claude finishes task → `Stop` hook fires → `task_complete` notification sent
2. Claude's output includes a permission request → `Notification` hook fires → `question` notification suppressed (within 12s)

Without this, users would get two notifications for the same logical event.

### Duplicate Message Detection

```go
func normalizeMessage(msg string) string {
    msg = strings.TrimSpace(msg)
    msg = strings.TrimRight(msg, ".")
    msg = strings.ToLower(msg)
    return msg
}

func (m *Manager) IsDuplicateMessage(sessionID, message string, windowSecs int) bool {
    state := m.loadState(sessionID)
    if state.LastNotificationMessage == "" { return false }
    elapsed := platform.CurrentTimestamp() - state.LastNotificationTime
    if elapsed >= int64(windowSecs) { return false }
    return normalizeMessage(message) == normalizeMessage(state.LastNotificationMessage)
}
```

The 180-second (3-minute) window catches the case where Stop and Notification hooks both fire and both pass the file-lock dedup (different lock files) but produce identical notification content.

---

## 7. Summary Generator: Text Extraction Heuristics

**File**: `internal/summary/summary.go`

### Question Text Extraction

For `StatusQuestion`, the generator tries three strategies in order:

```
1. Find AskUserQuestion tool in last 10 messages (within 60s of last message)
   → extract the "question" field from tool input
   → clean markdown, truncate to 150 chars

2. If no AskUserQuestion tool, search assistant text for sentences containing "?"
   → return first question sentence

3. Fallback: return first sentence of last assistant message
```

The 60-second window for AskUserQuestion prevents extracting stale questions from earlier in the conversation.

### Plan Text Extraction

For `StatusPlanReady`:
```
1. Find ExitPlanMode tool, extract "plan" input field
2. Split by newlines, find first non-empty line
3. Clean markdown, truncate to 150 chars
```

### Actions String Construction

```go
func buildActionsString(messages []jsonl.Message, userTS string) string {
    filtered := jsonl.FilterMessagesAfterTimestamp(messages, userTS)
    tools := jsonl.ExtractTools(filtered)

    writes, edits, bashes := 0, 0, 0
    for _, t := range tools {
        switch t.Name {
        case "Write":  writes++
        case "Edit":   edits++
        case "Bash":   bashes++
        }
    }

    // Calculate duration from first filtered message to last
    duration := calculateDuration(filtered)

    parts := []string{}
    if writes > 0 { parts = append(parts, fmt.Sprintf("📝 %d new", writes)) }
    if edits > 0  { parts = append(parts, fmt.Sprintf("✏️ %d edited", edits)) }
    if bashes > 0 { parts = append(parts, fmt.Sprintf("▶ %d cmds", bashes)) }
    if duration != "" { parts = append(parts, fmt.Sprintf("⏱ %s", duration)) }

    return strings.Join(parts, "  ")
}
```

### Markdown Cleaning Pipeline

`CleanMarkdown()` applies regex-based transformations in order:
1. Remove code blocks (`` ```...``` ``)
2. Convert images to alt text (`![alt](url)` → `alt`)
3. Convert links to text (`[text](url)` → `text`)
4. Remove strikethrough (`~~text~~` → `text`)
5. Remove bold (`**text**` → `text`)
6. Remove italic (`*text*` → `text`)
7. Remove inline backticks
8. Remove header markers (`###`)
9. Remove blockquote markers (`>`)
10. Remove bullet markers (`- `, `* `, `+ `)
11. Collapse whitespace to single spaces
12. Trim

---

## 8. Notifier: Platform Dispatch Matrix

**File**: `internal/notifier/notifier.go`

### Notification Title Construction

```go
func buildTitle(status, sessionLabel string) string {
    emoji := statusEmoji[status]  // "✅", "📋", "❓", etc.
    name := statusName[status]    // "Completed", "Plan Ready", "Question", etc.
    return fmt.Sprintf("%s %s [%s]", emoji, name, sessionLabel)
}
```

### Terminal Bell

```go
func sendTerminalBell() {
    f, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
    if err != nil { return }  // silently fail (may not have a tty)
    defer f.Close()
    f.Write([]byte("\a"))
}
```

The BEL character (`\a`) is sent to `/dev/tty` (not stdout) to ensure it reaches the actual terminal even when stdout is redirected. This triggers:
- tmux: window bell indicator (asterisk in status bar)
- Ghostty: tab color change
- Most terminals: visual or audible bell

### Sound Playback Lifecycle

```go
func (n *Notifier) playSoundAsync(soundPath string) {
    n.mu.Lock()
    if n.closing {
        n.mu.Unlock()
        return  // reject new sounds after Close() called
    }
    n.wg.Add(1)
    n.mu.Unlock()

    errorhandler.SafeGo(func() {
        defer n.wg.Done()
        n.playSound(soundPath)
    })
}

func (n *Notifier) Close() {
    n.mu.Lock()
    n.closing = true
    n.mu.Unlock()
    n.wg.Wait()  // block until all sounds finish
}
```

The `closing` flag prevents a race where `Close()` is called but a new sound goroutine starts between `Close()` and `wg.Wait()`, which would cause `wg.Wait()` to return before the new goroutine finishes.

---

## 9. Audio Player: PCM Streaming via CGO

**File**: `internal/audio/audio.go`

### Player Initialization

```go
func NewPlayer(deviceName string, volume float64) (*Player, error) {
    ctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, nil)
    if err != nil { return nil, err }

    var deviceID *malgo.DeviceID
    if deviceName != "" {
        devices, _ := ctx.Devices(malgo.Playback)
        for _, d := range devices {
            if strings.Contains(strings.ToLower(d.Name()), strings.ToLower(deviceName)) {
                id := d.ID
                deviceID = &id
                break
            }
        }
    }

    return &Player{ctx: ctx, deviceID: deviceID, volume: volume}, nil
}
```

Device matching is case-insensitive substring match. If no match is found, `deviceID` remains nil and malgo uses the system default.

### Audio Decoding

```go
func decodeAudio(path string) ([]int16, int, int, error) {
    ext := strings.ToLower(filepath.Ext(path))
    switch ext {
    case ".mp3":
        streamer, format, _ := mp3.Decode(f)
        return readAllSamples(streamer, format)
    case ".wav":
        streamer, format, _ := wav.Decode(f)
        return readAllSamples(streamer, format)
    case ".flac":
        streamer, format, _ := flac.Decode(f)
        return readAllSamples(streamer, format)
    case ".ogg":
        streamer, format, _ := vorbis.Decode(f)
        return readAllSamples(streamer, format)
    case ".aiff", ".aif":
        return decodeAIFF(f)  // uses go-audio/aiff directly
    }
}
```

The `readAllSamples()` function reads the beep.Streamer into a `[][2]float64` buffer, then converts to `[]int16` with clamping to prevent overflow.

### Volume Application

```go
for i := range samples {
    samples[i] = int16(float64(samples[i]) * player.volume)
}
```

Volume is applied in the PCM domain (software mixing). This avoids platform-specific volume APIs and works identically everywhere.

### malgo Device Configuration

```go
deviceConfig := malgo.DefaultDeviceConfig(malgo.Playback)
deviceConfig.Playback.Format = malgo.FormatS16
deviceConfig.Playback.Channels = uint32(channels)
deviceConfig.SampleRate = uint32(sampleRate)
deviceConfig.PeriodSizeInFrames = 4096
deviceConfig.Periods = 4
```

- **4096 frames per period**: Large enough to prevent underruns (buffer starvation that causes crackling)
- **4 periods**: Deep buffer chain prevents gaps between periods
- **FormatS16**: 16-bit signed integer PCM, the most universally supported format

### Data Callback (Streaming)

```go
dataCallback := func(outputSamples, inputSamples []byte, frameCount uint32) {
    bytesToCopy := int(frameCount) * channels * 2  // 2 bytes per S16 sample
    if offset+bytesToCopy > len(audioBytes) {
        bytesToCopy = len(audioBytes) - offset
    }
    copy(outputSamples, audioBytes[offset:offset+bytesToCopy])
    offset += bytesToCopy
    if offset >= len(audioBytes) {
        close(done)  // signal completion
    }
}
```

malgo calls this callback from a real-time audio thread. The callback must be fast — it just copies pre-computed bytes from the buffer.

### Drain Delay

```go
select {
case <-done:
    time.Sleep(200 * time.Millisecond)  // let audio hardware drain
case <-time.After(30 * time.Second):    // safety timeout
}
```

The 200ms delay after the `done` signal allows the audio hardware to play the last buffer. Without it, the final ~200ms of audio gets cut off when the device is immediately stopped.

---

## 10. Multiplexer Integration: Click-to-Focus Commands

**File**: `internal/notifier/multiplexer.go`

### Detection Order

```go
func detectMultiplexer() string {
    if os.Getenv("TMUX") != ""           { return "tmux" }
    if os.Getenv("ZELLIJ") != ""         { return "zellij" }
    if os.Getenv("WEZTERM_PANE") != ""   { return "wezterm" }
    if os.Getenv("KITTY_WINDOW_ID") != "" &&
       os.Getenv("KITTY_LISTEN_ON") != "" { return "kitty" }
    return ""
}
```

### tmux Focus Command

**File**: `internal/notifier/tmux.go`

```go
func buildTmuxFocusArgs(cwd string) []string {
    tmuxSocket := extractTmuxSocket()  // from $TMUX env var
    tmuxBin := findTmuxBinary()        // which tmux → absolute path
    paneID := os.Getenv("TMUX_PANE")   // e.g., "%42"

    // Build: tmux -S /tmp/tmux-501/default select-window -t %42 ; select-pane -t %42
    return []string{"-execute",
        fmt.Sprintf("%s -S %s select-window -t %s \\; select-pane -t %s",
            tmuxBin, tmuxSocket, paneID, paneID)}
}
```

Why absolute paths? The `-execute` command runs from `terminal-notifier` or `ClaudeNotifier.app`, which doesn't inherit the user's shell PATH. Using absolute paths ensures the command works regardless of the app's environment.

Why extract the socket path? tmux can use non-default sockets (`tmux -S /path/to/socket`). The `$TMUX` env var contains the socket path as its first field (colon-delimited).

### Zellij Focus Command

**File**: `internal/notifier/zellij.go`

```go
func buildZellijFocusArgs(cwd string) []string {
    sessionName := os.Getenv("ZELLIJ_SESSION_NAME")
    tabName := sessionname.GetZellijTabName()  // zellij action query-tab-names

    return []string{"-execute",
        fmt.Sprintf("zellij -s %s action go-to-tab-name %s", sessionName, tabName)}
}
```

### WezTerm Focus Command

**File**: `internal/notifier/wezterm.go`

```go
func buildWeztermFocusArgs() []string {
    paneID := os.Getenv("WEZTERM_PANE")
    return []string{"-execute",
        fmt.Sprintf("wezterm cli activate-pane --pane-id %s", paneID)}
}
```

### Kitty Focus Command

**File**: `internal/notifier/kitty.go`

```go
func buildKittyFocusArgs() []string {
    windowID := os.Getenv("KITTY_WINDOW_ID")
    listenOn := os.Getenv("KITTY_LISTEN_ON")
    return []string{"-execute",
        fmt.Sprintf("kitten @ --to %s focus-window --match id:%s", listenOn, windowID)}
}
```

---

## 11. macOS Focus: CGO Objective-C Bridge

**File**: `internal/notifier/ax_focus_darwin.go`

This file is the most technically complex in the codebase. It bridges Go and Objective-C to access macOS Accessibility and private CoreGraphics APIs.

### CGO Imports

```go
/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework ApplicationServices -framework AppKit -framework CoreGraphics
#include <ApplicationServices/ApplicationServices.h>
#include <AppKit/AppKit.h>

// Private CGS API declarations
extern int CGSGetOnScreenWindowList(int cid, int pid, int count, int *list, int *outCount);
extern int CGSGetWindowWorkspace(int cid, int wid, int *workspace);
extern int CGSSetWorkspace(int cid, int workspace);
extern int _CGSDefaultConnection(void);
*/
import "C"
```

### Ghostty Focus (AXDocument-based)

Ghostty sets the `AXDocument` accessibility attribute to the CWD as a `file://` URL (via OSC 7):

```go
func raiseWindowByAXDocument(pid int, fileURL string) bool {
    app := C.AXUIElementCreateApplication(C.pid_t(pid))
    defer C.CFRelease(C.CFTypeRef(app))

    var windows C.CFTypeRef
    C.AXUIElementCopyAttributeValue(app, kAXWindows, &windows)

    count := C.CFArrayGetCount(C.CFArrayRef(windows))
    for i := C.CFIndex(0); i < count; i++ {
        window := C.CFArrayGetValueAtIndex(C.CFArrayRef(windows), i)
        var docRef C.CFTypeRef
        C.AXUIElementCopyAttributeValue(window, kAXDocument, &docRef)
        doc := cfstringToGoString(docRef)
        if doc == fileURL {
            C.AXUIElementPerformAction(window, kAXRaiseAction)
            return true
        }
    }
    return false
}
```

### VS Code / Generic Focus (CGS Space Switching)

```go
func findSwitchAndActivate(pid int, folderName string) bool {
    cid := C._CGSDefaultConnection()

    // Get all windows for this PID
    var windowList [256]C.int
    var count C.int
    C.CGSGetOnScreenWindowList(cid, C.int(pid), 256, &windowList[0], &count)

    // Find window by title
    for i := 0; i < int(count); i++ {
        wid := windowList[i]
        title := getWindowTitle(wid)
        if strings.Contains(title, folderName) {
            // Switch to the Space containing this window
            var workspace C.int
            C.CGSGetWindowWorkspace(cid, wid, &workspace)
            if workspace > 0 {
                C.CGSSetWorkspace(cid, workspace)
            }
            activateApp(pid)
            return true
        }
    }
    return false
}
```

### Retry Logic

```go
func retryWindowFocus(fn func() bool) bool {
    for attempt := 0; attempt < 5; attempt++ {
        if fn() { return true }
        time.Sleep(100 * time.Millisecond)
    }
    return false
}
```

Window focus operations may fail transiently (the window isn't ready yet, the Space switch hasn't completed). The 5-attempt retry with 100ms delay handles these cases.

---

## 12. Linux Daemon: D-Bus IPC Protocol

**Files**: `internal/daemon/server.go`, `client.go`, `protocol.go`, `focus.go`

### Protocol Messages

```go
type MessageType string
const (
    MsgNotify MessageType = "notify"
    MsgPing   MessageType = "ping"
    MsgStop   MessageType = "stop"
)

type Request struct {
    Type    MessageType    `json:"type"`
    Notify  *NotifyRequest `json:"notify,omitempty"`
    Version string         `json:"version"`
}

type Response struct {
    Success bool   `json:"success"`
    Error   string `json:"error,omitempty"`
    Version string `json:"version"`
}
```

### Socket Path Selection

```go
func getSocketPath() string {
    if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
        return filepath.Join(dir, "claude-notifications.sock")
    }
    return fmt.Sprintf("/tmp/claude-notifications-%d.sock", os.Getuid())
}
```

`XDG_RUNTIME_DIR` (typically `/run/user/1000`) is preferred because it's a tmpfs with proper permissions. Fallback uses `/tmp` with UID to prevent socket conflicts between users.

### Server Lifecycle

```go
func (s *Server) Run() error {
    listener, _ := net.Listen("unix", s.socketPath)
    os.Chmod(s.socketPath, 0600)  // user-only access
    s.writePIDFile()

    go s.idleChecker()   // shutdown after 5 min idle
    go s.acceptLoop(listener)

    // Wait for shutdown signal
    select {
    case <-s.done:
    case sig := <-signals:
        // SIGINT or SIGTERM
    }
    listener.Close()
    os.Remove(s.socketPath)
    os.Remove(s.pidPath)
}
```

### Notification with Action Callback

```go
func (s *Server) handleNotification(req *NotifyRequest) error {
    n := notify.Notification{
        AppName: "Claude Code",
        Summary: req.Title,
        Body:    req.Body,
        Timeout: notify.Duration(req.Timeout) * notify.Second,
        Actions: []notify.Action{
            {Key: "default", Label: "Focus Terminal"},
        },
    }

    id, _ := s.notifier.SendNotification(n)

    // Store focus context for when user clicks
    s.focusCtx[id] = &focusInfo{
        target: req.FocusTarget,
        folder: req.FocusFolder,
    }
    return nil
}
```

When the user clicks the notification, D-Bus fires an `ActionInvoked` signal. The daemon's callback:

```go
func (s *Server) onActionInvoked(action *notify.ActionInvokedSignal) {
    ctx, ok := s.focusCtx[action.ID]
    if !ok { return }
    delete(s.focusCtx, action.ID)
    TryFocus(ctx.target, ctx.folder)
}
```

### Linux Focus Fallback Chain

```go
var focusMethods = []FocusMethod{
    {"activate-window-by-title", TryActivateWindowByTitle},  // GNOME extension
    {"GNOME Shell Eval (by title)", TryGnomeShellEvalByTitle},
    {"GNOME Shell Eval (by app)", TryGnomeShellEval},
    {"GNOME Shell FocusApp", TryGnomeFocusApp},
    {"wlrctl", TryWlrctl},     // Sway/wlroots
    {"kdotool", TryKdotool},   // KDE Plasma
    {"xdotool", TryXdotool},   // X11
}

func TryFocus(terminal, folder string) bool {
    for _, method := range focusMethods {
        if method.fn(terminal, folder) { return true }
    }
    return false
}
```

Each method checks for its tool/extension availability before attempting focus. The first successful method wins.

### Terminal Mappings

**File**: `internal/daemon/mappings.go`

Maps terminal application names to WM_CLASS values used by window managers:

```go
var terminalMappings = map[string]string{
    "ghostty":      "com.mitchellh.ghostty",
    "kitty":        "kitty",
    "alacritty":    "Alacritty",
    "wezterm":      "org.wezfurlong.wezterm",
    "gnome-terminal": "gnome-terminal-server",
    "konsole":      "konsole",
    "xfce4-terminal": "xfce4-terminal",
    // ... 14+ entries
}
```

---

## 13. Webhook: Resilience Stack

### Circuit Breaker

**File**: `internal/webhook/circuitbreaker.go`

```go
type CircuitBreaker struct {
    mu               sync.Mutex
    state            State          // Closed, Open, HalfOpen
    failures         int
    successes        int
    lastFailureTime  time.Time
    failureThreshold int            // default: 5
    successThreshold int            // default: 2
    timeout          time.Duration  // default: 30s
}

func (cb *CircuitBreaker) Execute(fn func() error) error {
    cb.mu.Lock()
    switch cb.state {
    case Open:
        if time.Since(cb.lastFailureTime) > cb.timeout {
            cb.state = HalfOpen  // try again
        } else {
            cb.mu.Unlock()
            return ErrCircuitOpen
        }
    }
    cb.mu.Unlock()

    err := fn()

    cb.mu.Lock()
    defer cb.mu.Unlock()
    if err != nil {
        cb.failures++
        cb.lastFailureTime = time.Now()
        if cb.state == HalfOpen || cb.failures >= cb.failureThreshold {
            cb.state = Open
        }
    } else {
        if cb.state == HalfOpen {
            cb.successes++
            if cb.successes >= cb.successThreshold {
                cb.state = Closed
                cb.failures = 0
                cb.successes = 0
            }
        } else {
            cb.failures = 0  // reset on success in Closed state
        }
    }
    return err
}
```

### Rate Limiter (Token Bucket)

**File**: `internal/webhook/ratelimiter.go`

```go
type RateLimiter struct {
    mu               sync.Mutex
    tokens           float64
    maxTokens        float64        // requestsPerMinute
    refillRate       float64        // requestsPerMinute / 60.0
    lastRefill       time.Time
}

func (rl *RateLimiter) Allow() bool {
    rl.mu.Lock()
    defer rl.mu.Unlock()

    elapsed := time.Since(rl.lastRefill).Seconds()
    rl.tokens = math.Min(rl.maxTokens, rl.tokens+elapsed*rl.refillRate)
    rl.lastRefill = time.Now()

    if rl.tokens >= 1.0 {
        rl.tokens -= 1.0
        return true
    }
    return false
}
```

### Retry with Exponential Backoff and Jitter

**File**: `internal/webhook/retry.go`

```go
func (r *Retryer) Do(fn func() error) error {
    var lastErr error
    for attempt := 0; attempt < r.maxAttempts; attempt++ {
        err := fn()
        if err == nil { return nil }

        lastErr = err
        if isNonRetryable(err) { return err }  // 4xx except 429

        backoff := r.initialBackoff * time.Duration(math.Pow(2, float64(attempt)))
        if backoff > r.maxBackoff { backoff = r.maxBackoff }

        // Add jitter: 0-25% of backoff
        jitter := time.Duration(rand.Float64() * 0.25 * float64(backoff))
        time.Sleep(backoff + jitter)
    }
    return lastErr
}
```

### Webhook Formatters

**File**: `internal/webhook/formatters.go`

Each formatter implements `Format(status, message, sessionID) ([]byte, string)` returning the JSON body and content type.

**Slack**: Uses `attachments` API with color-coded sidebars:
```json
{"attachments": [{"color": "#28a745", "title": "✅ Task Completed",
  "text": "Created factorial function", "footer": "Session: peak 73b5e210",
  "ts": 1709000000}]}
```

**Discord**: Uses `embeds` with integer color codes:
```json
{"embeds": [{"color": 2664261, "title": "✅ Task Completed",
  "description": "Created factorial function",
  "footer": {"text": "Session: peak 73b5e210"}}]}
```

**Telegram**: Uses HTML parse mode:
```json
{"chat_id": "123456789", "parse_mode": "HTML",
  "text": "<b>✅ Task Completed</b>\nCreated factorial function\n<i>Session: peak 73b5e210</i>"}
```

**Lark/Feishu**: Uses interactive card format:
```json
{"msg_type": "interactive", "card": {
  "config": {"wide_screen_mode": true},
  "header": {"template": "green", "title": {"tag": "plain_text", "content": "✅ Task Completed"}},
  "elements": [{"tag": "div", "text": {"tag": "plain_text", "content": "Created factorial function"}}]
}}
```

---

## 14. Configuration: Migration & Validation

**File**: `internal/config/config.go`

### Default Configuration

```go
func DefaultConfig() *Config {
    return &Config{
        Notifications: NotificationsConfig{
            Desktop: DesktopConfig{
                Enabled:      true,
                Sound:        true,
                TerminalBell: boolPtr(true),
                Volume:       1.0,
                ClickToFocus: false,
            },
            Webhook: WebhookConfig{
                Enabled: false,
                Retry: RetryConfig{
                    MaxAttempts:    3,
                    InitialBackoff: "1s",
                    MaxBackoff:     "10s",
                },
                CircuitBreaker: CircuitBreakerConfig{
                    FailureThreshold: 5,
                    SuccessThreshold: 2,
                    Timeout:          "30s",
                },
                RateLimit: RateLimitConfig{
                    RequestsPerMinute: 10,
                },
            },
            SuppressQuestionAfterTaskCompleteSeconds:    intPtr(12),
            SuppressQuestionAfterAnyNotificationSeconds: intPtr(0),
            SuppressForSubagents: boolPtr(true),
            NotifyOnTextResponse: boolPtr(true),
            RespectJudgeMode:     boolPtr(true),
        },
        Statuses: map[string]StatusInfo{
            "task_complete":         {Enabled: boolPtr(true), Sound: "sounds/task-complete.mp3"},
            "review_complete":       {Enabled: boolPtr(true), Sound: "sounds/review-complete.mp3"},
            "question":             {Enabled: boolPtr(true), Sound: "sounds/question.mp3"},
            "plan_ready":           {Enabled: boolPtr(true), Sound: "sounds/plan-ready.mp3"},
            "session_limit_reached": {Enabled: boolPtr(true), Sound: "sounds/error.mp3"},
            "api_error":            {Enabled: boolPtr(true), Sound: "sounds/error.mp3"},
            "api_error_overloaded": {Enabled: boolPtr(true), Sound: "sounds/error.mp3"},
        },
    }
}
```

### Atomic Config Migration

```go
func migrateConfig(src, dst string) error {
    data, err := os.ReadFile(src)
    if err != nil { return err }

    // Write to temp file in same directory (ensures same filesystem)
    dir := filepath.Dir(dst)
    os.MkdirAll(dir, 0755)
    tmpFile, err := os.CreateTemp(dir, ".config-migrate-*.json")
    if err != nil { return err }

    tmpFile.Write(data)
    tmpFile.Close()

    // Atomic rename (guaranteed atomic on same filesystem)
    return os.Rename(tmpFile.Name(), dst)
}
```

The temp file is created in the **same directory** as the destination to guarantee the rename is atomic (same filesystem). If the temp file were in a different directory/filesystem, `os.Rename` would fail or perform a copy+delete (non-atomic).

### Environment Variable Expansion

All path fields in config support `${CLAUDE_PLUGIN_ROOT}` and other env vars:

```go
func expandPaths(cfg *Config) {
    cfg.Notifications.Desktop.AppIcon = os.ExpandEnv(cfg.Notifications.Desktop.AppIcon)
    for status, info := range cfg.Statuses {
        info.Sound = os.ExpandEnv(info.Sound)
        cfg.Statuses[status] = info
    }
}
```

---

## 15. Error Handler: Panic Recovery Chain

**File**: `internal/errorhandler/errorhandler.go`

### Singleton Pattern

```go
var (
    handler     *ErrorHandler
    handlerOnce sync.Once
)

func Init(logToConsole, exitOnCritical, recoveryEnabled bool) {
    handlerOnce.Do(func() {
        handler = &ErrorHandler{
            logToConsole:    logToConsole,
            exitOnCritical:  exitOnCritical,
            recoveryEnabled: recoveryEnabled,
        }
    })
}
```

### SafeGo: Panic-Safe Goroutine Launcher

```go
func SafeGo(fn func()) {
    go WithRecovery(fn)
}

func WithRecovery(fn func()) {
    defer HandlePanic()
    fn()
}

func HandlePanic() {
    if handler == nil || !handler.recoveryEnabled { return }
    if r := recover(); r != nil {
        stack := string(debug.Stack())
        logging.Error("PANIC RECOVERED: %v\n%s", r, stack)
        if handler.exitOnCritical {
            os.Exit(1)
        }
    }
}
```

Every goroutine in the codebase uses `SafeGo()`. This means:
- A panic in sound playback doesn't crash the webhook send
- A panic in webhook formatting doesn't crash the desktop notification
- The main process always exits cleanly (with proper cleanup via defers)

---

## 16. Shell Infrastructure

### hook-wrapper.sh

**File**: `bin/hook-wrapper.sh`

Key sections:

**Platform detection**:
```bash
detect_platform() {
    case "$(uname -s)" in
        Darwin*)  PLATFORM="darwin" ;;
        Linux*)   PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        arm64|aarch64)  ARCH="arm64" ;;
    esac
}
```

**Version comparison and auto-update**:
```bash
BINARY_VERSION=$(get_binary_version)
PLUGIN_VERSION=$(get_plugin_version)

if [ "$BINARY_VERSION" != "$PLUGIN_VERSION" ]; then
    run_install --force
    if [ $? -eq 0 ]; then
        echo '{"systemMessage":"[claude-notifications] Updated to v'$PLUGIN_VERSION'"}'
    fi
fi
```

**Git text-symlink handling**:
```bash
# On Windows/some configs, Git creates symlinks as text files containing the target path
if [ -f "$BINARY" ] && [ ! -x "$BINARY" ]; then
    TARGET=$(cat "$BINARY")
    if [ -x "$PLUGIN_ROOT/bin/$TARGET" ]; then
        BINARY="$PLUGIN_ROOT/bin/$TARGET"
    fi
fi
```

### install.sh

**File**: `bin/install.sh`

Key features:

**GitHub availability check** (for air-gapped environments):
```bash
check_github_availability() {
    if curl -sL --max-time 5 "https://github.com" > /dev/null 2>&1; then
        return 0
    fi
    # Offline mode: use existing binary if present
    if [ -x "$INSTALL_DIR/$BINARY_NAME" ]; then
        OFFLINE_MODE=true
        return 0
    fi
    return 1
}
```

**SHA256 verification**:
```bash
verify_binary() {
    local file="$1"
    local expected_hash=$(grep "$BINARY_NAME" "$CHECKSUMS_FILE" | awk '{print $1}')
    local actual_hash=$(sha256sum "$file" | awk '{print $1}')

    if [ "$expected_hash" != "$actual_hash" ]; then
        echo "ERROR: Checksum mismatch!"
        return 1
    fi

    # Size check (binary should be > 1MB)
    local size=$(wc -c < "$file")
    if [ "$size" -lt 1048576 ]; then
        echo "ERROR: Binary too small ($size bytes)"
        return 1
    fi

    # Execution test
    "$file" version > /dev/null 2>&1
}
```

---

## 17. Swift Notifier: ClaudeNotifier.app

**Directory**: `swift-notifier/`

ClaudeNotifier.app is a macOS-native notification app that replaces the older `terminal-notifier` (which is unmaintained and has compatibility issues with newer macOS versions).

### Architecture

```
Sources/terminal-notifier-modern/
├── main.swift                          # Entry point, parse args, dispatch
├── CLI/
│   ├── ArgumentParser.swift            # Parse -title, -message, -execute, etc.
│   └── ExitCodes.swift                 # Exit code constants
├── App/
│   └── AppDelegate.swift               # NSApplication delegate lifecycle
├── Notification/
│   ├── NotificationService.swift       # Protocol + factory
│   ├── UNNotificationService.swift     # Modern API (macOS 10.14+)
│   ├── NSNotificationService.swift     # Legacy API (macOS 10.13)
│   ├── AppleScriptNotificationService.swift  # Fallback
│   ├── NotificationCategory.swift      # Action buttons
│   └── PermissionManager.swift         # Request notification permissions
└── Action/
    ├── ActionExecutor.swift             # Run shell command on click
    └── ClickAction.swift               # Parse click action from args
```

### Key Features

- **Three notification backends**: UNUserNotification (modern) → NSUserNotification (legacy) → AppleScript (fallback)
- **Click-to-focus**: `-execute` flag runs a shell command when the notification is clicked
- **Permission management**: Requests notification permissions on first run
- **-nosound flag**: Suppresses macOS notification sound (the Go binary plays its own sounds)

---

## 18. Complete File Inventory

### Go Source Files (34 non-test)

```
cmd/claude-notifications/main.go
cmd/claude-notifications/daemon_linux.go
cmd/claude-notifications/daemon_other.go
cmd/list-devices/main.go
cmd/list-sounds/main.go
cmd/sound-preview/main.go
internal/analyzer/analyzer.go
internal/audio/audio.go
internal/config/config.go
internal/daemon/client.go
internal/daemon/focus.go
internal/daemon/mappings.go
internal/daemon/protocol.go
internal/daemon/server.go
internal/dedup/dedup.go
internal/errorhandler/errorhandler.go
internal/hooks/hooks.go
internal/logging/logging.go
internal/notifier/ax_focus_darwin.go
internal/notifier/ax_focus_stub.go
internal/notifier/kitty.go
internal/notifier/multiplexer.go
internal/notifier/notifier.go
internal/notifier/terminal_darwin.go
internal/notifier/terminal_linux.go
internal/notifier/terminal_other.go
internal/notifier/tmux.go
internal/notifier/wezterm.go
internal/notifier/zellij.go
internal/platform/git.go
internal/platform/platform.go
internal/sessionname/sessionname.go
internal/sounds/sounds.go
internal/state/state.go
internal/summary/summary.go
internal/webhook/circuitbreaker.go
internal/webhook/formatters.go
internal/webhook/metrics.go
internal/webhook/ratelimiter.go
internal/webhook/retry.go
internal/webhook/webhook.go
pkg/jsonl/jsonl.go
```

### Go Test Files (48)

```
cmd/list-sounds/main_test.go
cmd/sound-preview/main_test.go
internal/analyzer/analyzer_test.go
internal/audio/audio_test.go
internal/config/config_test.go
internal/daemon/focus_test.go
internal/daemon/mappings_test.go
internal/daemon/protocol_test.go
internal/dedup/dedup_test.go
internal/errorhandler/errorhandler_test.go
internal/errorhandler/example_test.go
internal/hooks/hooks_test.go
internal/hooks/integration_test.go
internal/logging/logging_test.go
internal/notifier/kitty_test.go
internal/notifier/multiplexer_test.go
internal/notifier/notifier_darwin_integration_test.go
internal/notifier/notifier_test.go
internal/notifier/setup_test.go
internal/notifier/sound_test.go
internal/notifier/terminal_darwin_test.go
internal/notifier/terminal_other_test.go
internal/notifier/test_helpers_darwin_test.go
internal/notifier/tmux_e2e_test.go
internal/notifier/wezterm_test.go
internal/notifier/zellij_e2e_test.go
internal/platform/git_test.go
internal/platform/platform_test.go
internal/sessionname/sessionname_test.go
internal/sounds/sounds_test.go
internal/state/state_test.go
internal/summary/summary_test.go
internal/webhook/circuitbreaker_test.go
internal/webhook/formatters_test.go
internal/webhook/metrics_test.go
internal/webhook/ratelimiter_test.go
internal/webhook/retry_test.go
internal/webhook/webhook_test.go
pkg/jsonl/jsonl_test.go
```

### Shell Scripts (7)

```
setup.sh
bin/bootstrap.sh
bin/install.sh
bin/hook-wrapper.sh
bin/install_test.sh
bin/install_e2e_test.sh
bin/mock_server.py
```

### CI/CD Workflows (4)

```
.github/workflows/ci-macos.yml
.github/workflows/ci-ubuntu.yml
.github/workflows/ci-windows.yml
.github/workflows/release.yml
```

### Plugin Configuration (4)

```
.claude-plugin/plugin.json
.claude-plugin/marketplace.json
hooks/hooks.json
config/config.json
```

### Commands / Skills (6)

```
commands/init.md
commands/settings.md
commands/sounds.md
commands/notifications-init.md
commands/notifications-settings.md
commands/notifications-sounds.md
```

### Audio Assets (5)

```
sounds/task-complete.mp3
sounds/review-complete.mp3
sounds/question.mp3
sounds/plan-ready.mp3
sounds/error.mp3
```

### Swift Source Files (12 + 3 test)

```
swift-notifier/Sources/terminal-notifier-modern/main.swift
swift-notifier/Sources/terminal-notifier-modern/App/AppDelegate.swift
swift-notifier/Sources/terminal-notifier-modern/CLI/ArgumentParser.swift
swift-notifier/Sources/terminal-notifier-modern/CLI/ExitCodes.swift
swift-notifier/Sources/terminal-notifier-modern/Action/ActionExecutor.swift
swift-notifier/Sources/terminal-notifier-modern/Action/ClickAction.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/NotificationService.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/UNNotificationService.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/NSNotificationService.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/AppleScriptNotificationService.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/NotificationCategory.swift
swift-notifier/Sources/terminal-notifier-modern/Notification/PermissionManager.swift
swift-notifier/Tests/terminal-notifier-modernTests/ArgumentParserTests.swift
swift-notifier/Tests/terminal-notifier-modernTests/NotificationServiceTests.swift
swift-notifier/Tests/terminal-notifier-modernTests/ClickActionTests.swift
```
