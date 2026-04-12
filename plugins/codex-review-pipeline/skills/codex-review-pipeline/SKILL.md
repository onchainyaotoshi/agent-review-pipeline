---
name: codex-review-pipeline
description: 2-stage code review pipeline (correctness + adversarial) via Codex with auto-fix loop — run when user asks to review a PR, check code, or validate before commit
argument-hint: "[-n N] [PR number | files or scope to review]"
---

# Codex Review Pipeline

Run a 2-stage review pipeline (correctness + adversarial) powered by Codex, with automatic fix-and-retry until all reviews pass. Fully automatic — no manual trigger per stage.

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `maxIterations` | `3` | Max auto-fix iterations per review stage before escalating (`0` = unlimited) |
| `failOnError` | `false` | Abort pipeline on first stage that can't PASS (instead of escalating) |

**Set globally** via plugin config:
```
/plugin config codex-review-pipeline
```

**Override per-run** via CLI flags:
```
/codex-review-pipeline -n 5 42       # max 5 iterations per stage
/codex-review-pipeline -n 0 42       # yolo mode — run until PASS, no limit
/codex-review-pipeline 42            # default (3)
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--max-iterations N` | `-n N` | Max auto-fix iterations per stage (`0` = unlimited) |

CLI flags take precedence over plugin config.

## Prerequisites

- **Codex CLI** (`@openai/codex`) installed and authenticated
- **Codex plugin** for Claude Code — install first:
  ```
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
  ```

If the Codex plugin is not installed, inform the user and stop.

## When to Use

- **Only when the user asks** — "review PR 42", "review this", "check before commit", "run the pipeline"
- Or when the user asks to commit — run before committing
- **DO NOT** run automatically after every coding session — the user may want to test and approve first.

## Pipeline

```
┌─────────────────────┐
│ 1. /codex:review     │ ← correctness: logic, null checks, missing functions
│    (auto-fix loop)   │
└────────┬────────────┘
         │ issues? → fix → re-run (max N)
         │ PASS ↓
┌─────────────────────┐
│ 2. /codex:adversarial-review │ ← break it: edge cases, data loss, race conditions
│    (auto-fix loop)            │
└────────┬─────────────────────┘
         │ issues? → fix → re-run (max N)
         │ PASS ↓
┌─────────────────────┐
│   3. DELIVER         │ ← summary with iteration counts and all fixes applied
└─────────────────────┘
```

## How to Run

### Step 0: Parse Arguments & Resolve Input

**Parse CLI flags** from the argument string:
- `-n N` or `--max-iterations N` — override `maxIterations` for this run
- Everything else is treated as the review target

**Determine what to review:**

| Argument | Action |
|----------|--------|
| PR number (e.g. `42`) | Run `gh pr diff <number>` to get changed files, then review those |
| Branch name | Run `git diff main...<branch>` to get changed files |
| File paths | Review those files directly |
| No argument | Run `git diff --name-only main...HEAD` on the current branch |

### Step 1: Correctness Review

Run `/codex:review` on the resolved files.

**If findings found:**
1. Read each finding (severity, file, line, recommendation)
2. Fix all issues using Edit tool
3. Re-run `/codex:review` on the same files
4. Repeat until PASS (max `maxIterations`)

**If PASS:** advance to Step 2.

### Step 2: Adversarial Review

Run `/codex:adversarial-review` on the same files.

**If findings found:**
1. Read each finding (severity, confidence, file, line, recommendation)
2. Fix all issues using Edit tool
3. Re-run `/codex:adversarial-review` on the same files
4. Repeat until PASS (max `maxIterations`)

**If PASS:** advance to Step 3.

### Step 3: Deliver

Present a summary to the user:

```
Codex Review Pipeline: PASS

Correctness (N iterations):
- Fix 1: [description]
- Fix 2: [description]

Adversarial (N iterations):
- Fix 1: [description]
- Fix 2: [description]

All fixes applied. Ready to test.
```

## Rules

1. **Use Codex review commands** — `/codex:review` for correctness, `/codex:adversarial-review` for adversarial. Do NOT use `codex:codex-rescue` for review work.
2. **Auto-fix within the pipeline** — Unlike standalone review mode (which stops and asks the user), this pipeline auto-fixes all issues inline and re-runs. This overrides the default `codex-result-handling` behavior because the user explicitly invoked the pipeline.
3. **Never skip adversarial** — A PASS on correctness does not mean the code is safe. Adversarial catches bugs that correctness review misses.
4. **Max iterations per step** — Default 3, configurable via `maxIterations` in plugin config or `-n` flag. Set `0` for unlimited (yolo mode — runs until PASS, no escalation). Otherwise, if still failing after N fix attempts: if `failOnError` is true, abort pipeline; otherwise, stop and escalate to the user with a list of remaining issues.
5. **Scope per step** — Only include relevant files, not the entire codebase. More focused = more accurate review.
6. **Deliver with summary** — After both pass, tell the user: what was reviewed, iteration counts per stage, what was fixed.

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
