# Release Checklist

Step-by-step guide for publishing a new version.

## 1. Bump version

Update the version string in **3 files** (4 occurrences total):

| File | Location | Count |
|------|----------|-------|
| `cmd/claude-notifications/main.go` | `const version = "X.Y.Z"` | 1 |
| `.claude-plugin/plugin.json` | `"version": "X.Y.Z"` | 1 |
| `.claude-plugin/marketplace.json` | `"version": "X.Y.Z"` | 2 |

Quick check — all occurrences should match:

```bash
grep -rn '1\.[0-9]\+\.[0-9]\+' cmd/claude-notifications/main.go .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

## 2. Update CHANGELOG.md

Add a new section at the top following [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

## 3. Run tests

```bash
make test-race
make lint
```

## 4. Commit and tag

```bash
git add -A
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

## 5. GitHub Release

The `release.yml` workflow triggers on tag push and builds binaries for all platforms automatically.

Verify at: https://github.com/777genius/claude-notifications-go/releases

## 6. Update release description

The auto-generated release description is minimal. Edit it with a human-readable summary:

```bash
gh release edit vX.Y.Z --notes "$(cat <<'NOTES_EOF'
## Bug Fixes

### Title ([#N](link))
Description of what was broken and how it was fixed.

## New Features

### Title ([#N](link))
Description of what was added and why.

---

**Full Changelog**: https://github.com/777genius/claude-notifications-go/compare/vPREV...vX.Y.Z
NOTES_EOF
)"
```

## 7. Notify relevant issues/PRs

Comment on fixed issues and merged PRs with a link to the release:

```bash
gh issue comment N --body "Fixed in [vX.Y.Z](https://github.com/777genius/claude-notifications-go/releases/tag/vX.Y.Z)."
gh pr comment N --body "Released in [vX.Y.Z](https://github.com/777genius/claude-notifications-go/releases/tag/vX.Y.Z)."
```

## How auto-update works

Users don't need to manually download binaries after a plugin update:

1. User updates the plugin via `/plugin` menu
2. This updates `plugin.json` with the new version
3. On the next hook invocation, `bin/hook-wrapper.sh` compares the installed binary version with `plugin.json`
4. If versions differ, it runs `install.sh --force` to download the matching binary from GitHub Releases
5. User sees a `[claude-notifications] Updated to vX.Y.Z` message
