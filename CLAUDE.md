# CLAUDE.md

## Build & test

```bash
make build                # dev build (debug symbols) → bin/
make test                 # go test -v -cover ./...
make test-race            # go test -v -race -cover ./...
make lint                 # go vet + go fmt
go test ./internal/hooks -v -run TestHandler_PreToolUse  # single test
```

CGO is required (`CGO_ENABLED=1`). On Linux: `sudo apt-get install libasound2-dev`.

## Version bumping

Version lives in 3 files (4 occurrences) — all must match:

| File | Location |
|------|----------|
| `cmd/claude-notifications/main.go` | `const version = "X.Y.Z"` |
| `.claude-plugin/plugin.json` | `"version": "X.Y.Z"` |
| `.claude-plugin/marketplace.json` | `"version": "X.Y.Z"` (appears twice) |

## Architecture rules

- `internal/hooks/hooks.go` is the **single orchestration layer** — all other packages are leaf dependencies with no back-references. Never introduce circular imports.
- The binary is **short-lived** (one process per hook invocation). No long-running state except the Linux daemon. All persistence goes through file-system state files in `$TMPDIR`.
- Platform-specific code uses **file suffixes** (`_darwin.go`, `_linux.go`, `_other.go`) and build tags, not runtime `if/else` on `GOOS`.
- New goroutines must use `errorhandler.SafeGo()` — never bare `go func()`.
- Interfaces for testing: `Handler` uses `notifierInterface` and `webhookInterface`. Mock these in tests instead of the concrete types.

## Code conventions

- Standard `go fmt` formatting, no custom style.
- Imports: stdlib first, then third-party, then internal (goimports ordering).
- Errors: use `errorhandler.HandleError()` for non-fatal, `errorhandler.HandleCriticalError()` for fatal. Never `log.Fatal` or `panic`.
- Config fields that are optional booleans/ints use pointer types (`*bool`, `*int`) with helper constructors (`boolPtr()`, `intPtr()`).
- Sound paths in config support `${CLAUDE_PLUGIN_ROOT}` via `os.ExpandEnv`.

## Testing conventions

- Most packages use stdlib `testing` assertions (`t.Fatal`, `t.Error`, `t.Errorf`).
- Some packages (`pkg/jsonl`, `internal/dedup`, `internal/state`, `internal/config`, `internal/platform`, `internal/sessionname`) use `testify/assert` and `testify/require` — follow whichever the package already uses.
- Table-driven tests with `t.Run()` for state machine and parsing tests.
- Use `t.TempDir()` for temp files. Use `t.Setenv()` for env vars (auto-restored).
- Use `setTestHome(t, dir)` helper to isolate `os.UserHomeDir()` in tests.
- Helper functions: `buildUserMessage()`, `buildAssistantWithTools()`, `buildTranscriptFile()` for JSONL fixtures.
- Integration tests use `//go:build integration` tag — not run in normal `go test`.
- E2E multiplexer tests (`tmux_e2e_test.go`, `zellij_e2e_test.go`) require the real multiplexer installed.

## Git & commit conventions

- Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `release:`.
- Branch names: `feat/description` or `fix/description`.
- Tag releases: `git tag vX.Y.Z && git push origin main --tags` triggers the release workflow.

## Key gotchas

- **Dedup lock files are never explicitly released** — they age out after 2 seconds. This is intentional (crash-safe design). Don't add `defer os.Remove(lockPath)`.
- **The 15-message window in analyzer** prevents ghost statuses from old transcript history. Don't remove the `getLastN(filtered, 15)` call.
- **Temporal isolation**: `FilterMessagesAfterTimestamp(messages, userTS)` is critical — without it, old `ExitPlanMode` causes false `plan_ready` on every Stop. Don't bypass this filter.
- **Content lock (5s TTL)** is separate from per-hook dedup locks (2s TTL). It prevents Stop+Notification race for the same content.
- **Config loads from stable path first** (`~/.claude/claude-notifications-go/config.json`), not the plugin root. The plugin-root path is legacy and auto-migrated.
- **hook-wrapper.sh auto-updates the binary** by comparing `binary version` against `plugin.json`. The binary version const must match plugin.json exactly.
- **Audio drain delay** (200ms after playback completes) prevents the last audio buffer from being cut off. Don't remove it.
- **macOS focus uses private CGS API** (`ax_focus_darwin.go`) — these are undocumented Apple APIs. Expect breakage on major macOS updates.
- **Subagent detection** checks if `transcript_path` contains `/subagents/`. This is a heuristic, not a formal API contract.

## CI

- 3 platform CIs: `ci-macos.yml`, `ci-ubuntu.yml`, `ci-windows.yml` — all must pass.
- Go 1.21 and 1.22 matrix, `fail-fast: false`.
- Release workflow (`release.yml`) uses **native runners** for each platform because CGO cannot cross-compile. Don't switch to cross-compilation.
- Coverage uploaded to Codecov from Ubuntu CI only (Go 1.21 matrix entry).
