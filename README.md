# codex-review-pipeline

Automated 2-stage code review pipeline for [Claude Code](https://claude.ai/code), powered by [Codex](https://github.com/openai/codex-plugin-cc).

## What It Does

Runs a multi-stage quality gate on your code before shipping:

1. **Correctness Review** — logic errors, null derefs, missing functions, type mismatches, missing error handling
2. **Adversarial Review** — actively tries to *break* your code: edge cases, data loss, race conditions, validation bypass, overflow
3. **Deliver** — summary of what was reviewed, how many iterations, and what was fixed

Each stage auto-fixes issues and re-runs until PASS (max 3 iterations). If it can't fix everything, it escalates with a list of remaining issues.

```
┌─────────────────┐
│  1. CODEX REVIEW │ ← correctness: logic, null checks, missing functions
│    (correctness) │
└────────┬────────┘
         │ issues? → fix → retry (max 3x)
         │ PASS ↓
┌─────────────────┐
│ 2. CODEX ADVERSARIAL │ ← break it: edge cases, data loss, race conditions
│    (break it)        │
└────────┬────────┘
         │ issues? → fix → retry (max 3x)
         │ PASS ↓
┌─────────────────┐
│   3. DELIVER     │ ← summary with iteration counts and fixes applied
└─────────────────┘
```

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex plugin](https://github.com/openai/codex-plugin-cc) — install first:

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

```
/codex-review-pipeline src/auth.js src/handlers/
```

Or just ask Claude:
> "Review these files before commit"

The pipeline runs automatically — no manual trigger per stage.

## Example Output

```
Codex Review Pipeline: PASS

Review (2 iterations):
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
