# Contributing

Thank you for your interest in contributing to Claude Notifications!

## Prerequisites

- **Go 1.21+** (tested with 1.25)
- **Make** (for build commands)
- **Claude Code** (tested on v2.0.15)

## Getting Started

### 1. Clone and build

```bash
git clone https://github.com/777genius/claude-notifications-go
cd claude-notifications-go
make build
```

### 2. Install as local plugin

```bash
# Add as local marketplace
/plugin marketplace add .

# Install plugin
/plugin install claude-notifications-go@local-dev

# Restart Claude Code for hooks to take effect

# Download binary and configure settings
/claude-notifications-go:init
/claude-notifications-go:settings
```

`/claude-notifications-go:init` will use your locally built binary from `bin/` if it exists, otherwise it downloads from GitHub Releases.

## Project Structure

See [Architecture](docs/ARCHITECTURE.md) for a detailed overview. Key directories:

| Directory | Description |
|-----------|-------------|
| `cmd/` | CLI entry points (`claude-notifications`, `sound-preview`, `list-devices`, `list-sounds`) |
| `internal/` | Core logic (analyzer, hooks, notifier, webhook, config, audio, etc.) |
| `pkg/jsonl/` | JSONL streaming parser |
| `commands/` | Plugin skill definitions (`.md` files) |
| `sounds/` | Built-in notification sounds (MP3) |

## Make Targets

```bash
make help              # Show all available targets
make build             # Build binaries (development mode with debug symbols)
make build-all         # Build optimized binaries for all platforms
make test              # Run tests with coverage
make test-race         # Run tests with race detection
make test-coverage     # Generate HTML coverage report
make lint              # Run go vet + go fmt
make clean             # Clean build artifacts
make rebuild-and-commit  # Rebuild optimized binaries for all platforms
```

## Testing

### Run all tests

```bash
make test
```

### Run specific packages

```bash
go test ./internal/analyzer -v
go test ./internal/hooks -v
go test ./internal/config -v
go test ./internal/dedup -v -race
```

### Integration tests

```bash
go test ./test -v
```

### Run a single test

```bash
go test -run TestStateMachine ./internal/analyzer -v
```

### Coverage

```bash
make test-coverage
open coverage.html
```

## CI/CD

GitHub Actions run on every push:

- **ci-ubuntu.yml** — Tests on Ubuntu
- **ci-macos.yml** — Tests on macOS
- **ci-windows.yml** — Tests on Windows
- **release.yml** — Builds and publishes release binaries

All three platform CIs must pass before merging.

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes
4. Run tests: `make test-race`
5. Run linter: `make lint`
6. Commit with a descriptive message following [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat:` — new features
   - `fix:` — bug fixes
   - `docs:` — documentation changes
   - `test:` — adding/updating tests
   - `chore:` — maintenance tasks
7. Open a Pull Request against `main`

## Releasing

See **[Release Checklist](docs/RELEASE.md)** for the full step-by-step guide.

## Code Style

- Standard Go formatting (`go fmt`)
- Use `go vet` for static analysis
- Keep functions focused and small
- Add tests for new functionality
- Use structured logging via `internal/logging` package

## Reporting Issues

Found a bug or have a feature request? [Open an issue](https://github.com/777genius/claude-notifications-go/issues).
