# codex-review-pipeline

Automated 2-stage code review pipeline for [Claude Code](https://claude.ai/code), powered by [Codex](https://github.com/openai/codex-plugin-cc).

## What It Does

Chains Codex's built-in review commands into a single pipeline with **automatic fix-and-retry**:

1. **Correctness Review** (`/codex:review`) — logic errors, null derefs, missing functions, type mismatches
2. **Adversarial Review** (`/codex:adversarial-review`) — actively tries to *break* your code: edge cases, data loss, race conditions, validation bypass
3. **Deliver** — summary of what was reviewed, iteration counts, and all fixes applied

Each stage auto-fixes issues and re-runs until PASS (max 3 iterations). If it can't fix everything, it escalates with a list of remaining issues.

```
┌─────────────────────┐
│ 1. /codex:review     │ ← correctness: logic, null checks, missing functions
│    (auto-fix loop)   │
└────────┬────────────┘
         │ issues? → fix → re-run (max 3x)
         │ PASS ↓
┌─────────────────────┐
│ 2. /codex:adversarial-review │ ← break it: edge cases, data loss, race conditions
│    (auto-fix loop)            │
└────────┬─────────────────────┘
         │ issues? → fix → re-run (max 3x)
         │ PASS ↓
┌─────────────────────┐
│   3. DELIVER         │ ← summary with iteration counts and all fixes applied
└─────────────────────┘
```

## How It Differs from Running Codex Reviews Manually

| Standalone Codex Review | This Pipeline |
|--------------------------|---------------|
| Run `/codex:review` or `/codex:adversarial-review` separately | Both chained automatically |
| Stops after review — you fix manually | Auto-fixes and re-runs until PASS |
| No PR integration | Accepts PR number, branch, or file paths |
| Separate results per command | Combined summary at the end |

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- [Codex plugin](https://github.com/openai/codex-plugin-cc) for Claude Code:

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
```

## Installation

```
/plugin marketplace add onchainyaotoshi/codex-review-pipeline
/plugin install codex-review-pipeline@codex-review-pipeline
/reload-plugins
```

## Usage

Review a pull request:
```
/codex-review-pipeline 42
```

Auto-detect (no argument) — if 1 PR open, use it; if 2+, ask which one:
```
/codex-review-pipeline
```

Review specific files:
```
/codex-review-pipeline src/auth.js src/handlers/
```

### Flags

| Flag | Alias | Description |
|------|-------|-------------|
| `--max-iterations N` | `-n N` | Max auto-fix iterations per stage (default: 3) |

Yolo mode — unlimited iterations, run until PASS:
```
/codex-review-pipeline -n 0 42
```

Custom max iterations:
```
/codex-review-pipeline -n 5 42
```

Or just ask Claude:
> "Review PR 42" / "Check this before commit"

The pipeline runs automatically — no manual trigger per stage.

## Example Output

```
Codex Review Pipeline: PASS

Correctness (2 iterations):
- Fix 1: null guard on update()
- Fix 2: qty_kurang not included in submit filter

Adversarial (3 iterations):
- Fix 1: Grand total double-count (desktop + mobile subtotal nodes)
- Fix 2: Sync stale on blur (data-last-edit tracking)
- Fix 3: Submit validation — empty rows, product without qty

All fixes applied. Ready to test.
```

## License

MIT
