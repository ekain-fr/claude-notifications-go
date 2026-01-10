# Release Checklist

## Version Bump

When releasing a new version, update version in these files:

1. `cmd/claude-notifications/main.go` - `const version = "X.Y.Z"`
2. `.claude-plugin/plugin.json` - `"version": "X.Y.Z"`
3. `.claude-plugin/marketplace.json` - `"version": "X.Y.Z"` (appears twice: in metadata and plugins)
4. `CHANGELOG.md` - add new `## [X.Y.Z] - YYYY-MM-DD` section at the top

## Release Steps

1. Update all version numbers (see above)
2. Update CHANGELOG.md with changes
3. Commit: `git commit -m "chore: bump version to X.Y.Z"`
4. Push to main
5. Create GitHub release: `gh release create vX.Y.Z --title "vX.Y.Z - <title>" --notes "<notes>"`
