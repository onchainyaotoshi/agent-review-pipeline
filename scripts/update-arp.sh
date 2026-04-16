#!/bin/bash
# update-arp.sh — Update agent-review-pipeline plugin
# Usage: bash scripts/update-arp.sh

set -e

MARKETPLACE="onchainyautoshi/agent-review-pipeline"
CURRENT_VERSION=$(jq -r '.version' plugins/agent-review-pipeline/.claude-plugin/plugin.json 2>/dev/null || echo "unknown")

echo "=== Updating ARP Plugin ==="
echo "Current version: $CURRENT_VERSION"

echo ""
echo ">>> Step 1: Reload plugins to fetch latest marketplace..."
/reload-plugins 2>/dev/null || true

echo ""
echo ">>> Step 2: Install latest ARP from $MARKETPLACE..."
/plugin install agent-review-pipeline@$MARKETPLACE

echo ""
echo ">>> Step 3: Reload to activate new version..."
/reload-plugins

echo ""
echo "=== Done ==="
echo "Run /arp to verify."