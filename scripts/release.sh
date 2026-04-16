#!/bin/bash
# release.sh — Manual version bump + release
# Usage: ./release.sh <version> [message]
# Example: ./release.sh 6.3.2 "feat: add new header"

set -e

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./release.sh <version> [message]"
  echo "Example: ./release.sh 6.3.2 \"feat: add new header\""
  exit 1
fi

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Version must be semver (e.g. 6.3.2)"
  exit 1
fi

MSG="${2:-release: bump to v$VERSION}"

echo "===== Release v$VERSION ====="

# Update plugin.json
sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" plugins/agent-review-pipeline/.claude-plugin/plugin.json
echo "  plugin.json: updated to $VERSION"

# Update marketplace.json
sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" .claude-plugin/marketplace.json
echo "  marketplace.json: updated to $VERSION"

# Update SKILL.md version line
sed -i "s/^version: .*/version: $VERSION/" plugins/agent-review-pipeline/skills/arp/SKILL.md
echo "  SKILL.md: updated to $VERSION"

# Update manifest
sed -i "s/\"\\.\": \"[^\"]*\"/\"\\.\": \"$VERSION\"/" .github/.release-please-manifest.json
echo "  manifest: updated to $VERSION"

# Commit
git add -A
git commit -m "$MSG"
echo "  Commit: $MSG"

# Create tag
git tag "v$VERSION"
echo "  Tag: v$VERSION created"

# Push
git push origin main --follow-tags
echo "  Pushed to origin/main with tags"

# Create GitHub release
gh release create "v$VERSION" --title "agent-review-pipeline: v$VERSION" --notes "$MSG" --repo onchainyaotoshi/agent-review-pipeline
echo "  GitHub release v$VERSION created"

echo "===== Done: v$VERSION released ====="