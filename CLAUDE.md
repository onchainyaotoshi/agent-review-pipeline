# Agent Review Pipeline — Plugin Repo

## Session Start: Plugin Status Report

On every new session, run this diagnostic and report the result to the user:

```bash
echo "=== ARP Plugin Status ===" && echo -n "Source:  " && jq -r '.version' plugins/agent-review-pipeline/.claude-plugin/plugin.json 2>/dev/null || echo "parse fail" && echo -n "Tag:     " && git describe --tags --abbrev=0 2>/dev/null || echo "no tags" && echo -n "Cached:  " && ls -d ~/.claude/plugins/cache/agent-review-pipeline/agent-review-pipeline/*/ 2>/dev/null | sed 's|.*/||' | tr '\n' ' ' && echo && echo -n "Dirty:   " && git status --short | head -5 | wc -l && git status --short | head -5 && echo "=== End ==="
```

Report format:
- If cache version != source version → warn: "plugin cache stale, run `/plugin install agent-review-pipeline@agent-review-pipeline && /reload-plugins`"
- If latest tag < source version → warn: "source ahead of tag, release PR may be needed"
- If uncommitted changes → list them

## Repo Structure

```
plugins/agent-review-pipeline/   # The actual Claude Code plugin
  .claude-plugin/plugin.json     # Plugin manifest + version
  skills/arp/SKILL.md            # Main skill definition + version
.claude-plugin/marketplace.json  # Marketplace catalog (version must match plugin.json)
scripts/                         # Utility scripts
docs/specs/                      # Design specs
```

## Version Management

Version is defined in **3 files** — must stay in sync:
1. `plugins/agent-review-pipeline/.claude-plugin/plugin.json` → `.version`
2. `plugins/agent-review-pipeline/skills/arp/SKILL.md` → line 3 `version: X.Y.Z`
3. `.claude-plugin/marketplace.json` → `.plugins[0].version`

`release-please` handles bumps automatically via `.github/workflows/release-pr.yml`.

## ARP Invocation

- Default engine: `both` (Codex + Gemini)
- Engines: `both`, `codex`, `gemini`
- Dry-run: set `dryRun: true` in plugin config or pass `--dry-run`
- Max iterations: 1-10 (default 3)
- Quality Gate: enabled by default (semantic dedup + classifier + enhanced rules)

## Key Constraints

- Auto-commit and PR comment default **off** (safe-off)
- Gemini model pinned to `gemini-3-flash-preview` since v5.3.0
- `compound-engineering-plugin/` is a vendored dependency for Gemini skills
