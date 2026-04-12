---
name: codex-review-pipeline
description: 3-stage code review pipeline (correctness + impact analysis + adversarial) via Codex with auto-fix loop — run when user asks to review a PR, check code, or validate before commit
argument-hint: "[-n N] [PR number | files or scope to review]"
---

# Codex Review Pipeline

Run a 3-stage review pipeline (correctness → impact analysis → adversarial) powered by Codex, with automatic fix-and-retry until all reviews pass. Fully automatic — no manual trigger per stage.

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

- **Codex plugin** for Claude Code (provides the `codex:codex-rescue` subagent used internally)

## When to Use

- **Only when the user asks** — "review PR 42", "review this", "check before commit", "run the pipeline"
- Or when the user asks to commit — run before committing
- **DO NOT** run automatically after every coding session — the user may want to test and approve first.

## Pipeline

```
┌─────────────────────┐
│ 1. Correctness       │ ← logic errors, null checks, missing functions
│    (auto-fix loop)   │
└────────┬────────────┘
         │ issues? → fix → re-run (max N)
         │ PASS ↓
┌─────────────────────┐
│ 2. Impact Analysis   │ ← does this break other menus / callers?
│    (auto-fix loop)   │
└────────┬────────────┘
         │ breaking? → fix → re-run (max N)
         │ SAFE ↓
┌─────────────────────┐
│ 3. Adversarial       │ ← break it: edge cases, data loss, race conditions
│    (auto-fix loop)   │
└────────┬────────────┘
         │ issues? → fix → re-run (max N)
         │ PASS ↓
┌─────────────────────┐
│   4. DELIVER         │ ← summary with iteration counts and all fixes applied
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
| No argument | Auto-detect via `gh` (see below) |

**Auto-detect (no argument):**

1. Run `gh pr list --state open --json number,title,headRefName`
2. **If 0 open PRs** → Run `git diff --name-only main...HEAD` on the current branch instead
3. **If 1 open PR** → Use that PR automatically
4. **If 2+ open PRs** → Show the list and ask the user which PR to review

### Step 1: Correctness Review

Use the Agent tool with `subagent_type: "codex:codex-rescue"` and this prompt:

```
Review [files]. Check for: logic errors, null derefs, missing functions,
column/data mismatches, type mismatches, missing error handling.
Report PASS or list issues with file:line.
```

**If findings found:**
1. Read each finding (severity, file, line, recommendation)
2. Fix all issues using Edit tool
3. Re-run the Agent with the same correctness prompt on the same files
4. Repeat until PASS (max `maxIterations`)

**If PASS:** advance to Step 2.

### Step 2: Impact Analysis

Use the Agent tool with `subagent_type: "codex:codex-rescue"` and this prompt:

```
Impact analysis for changes in [files].

1. IDENTIFY: what functions/classes/exports/APIs changed? Old vs new signature.
2. FIND DEPENDENTS: search the entire codebase for all files that import or use
   the changed symbols (use grep/glob — be thorough).
3. ASSESS each dependent:
   - Is the change backward-compatible?
   - Could it break the dependent file's behavior?
   - Pay special attention to:
     * consumer_scripts/ — menu-specific scripts (each menu is a user-facing page)
     * Other components that extend or compose the changed components
     * Callers that rely on the old return type, function signature, or side effects
4. Report SAFE if no breaking changes, or list each affected file with:
   - What it uses from the changed file
   - Why it might break
   - Severity (Critical/High/Medium/Low)
```

**If breaking impacts found:**
1. Fix the change to be backward-compatible, OR update all affected dependents
2. Re-run the Agent with the same impact prompt
3. Repeat until SAFE (max `maxIterations`)

**If SAFE:** advance to Step 3.

### Step 3: Adversarial Review

Use the Agent tool with `subagent_type: "codex:codex-rescue"` and this prompt:

```
ADVERSARIAL review [files]. Try to BREAK this code. Think like a hostile tester.
Construct failure scenarios: edge cases, data loss, double-counting, stale state,
race conditions, bypass validation, overflow, empty/null inputs.
Focus on ACTUAL BUGS that crash or produce wrong data.
Report each with severity (Critical/High/Medium/Low) and file:line.
```

**If findings found:**
1. Read each finding (severity, confidence, file, line, recommendation)
2. Fix all issues using Edit tool
3. Re-run the Agent with the same adversarial prompt on the same files
4. Repeat until PASS (max `maxIterations`)

**If PASS:** advance to Step 4.

### Step 4: Deliver

Present a summary to the user:

```
Codex Review Pipeline: PASS

Correctness (N iterations):
- Fix 1: [description]

Impact Analysis (N iterations):
- Checked N dependent files — SAFE / Fix 1: [description]

Adversarial (N iterations):
- Fix 1: [description]

All fixes applied. Ready to test.
```

## Rules

1. **Use `codex:codex-rescue` subagent** via the Agent tool — NOT via the Skill tool. `codex:review` and `codex:adversarial-review` skills cannot be invoked programmatically (disable-model-invocation restriction).
2. **Auto-fix within the pipeline** — Unlike standalone review mode, this pipeline auto-fixes all issues inline and re-runs.
3. **Never skip impact analysis** — Correctness PASS only means the changed file is internally correct. Impact analysis checks whether other menus/callers are broken.
4. **Never skip adversarial** — A PASS on correctness does not mean the code is safe. Adversarial catches bugs that correctness review misses.
5. **Max iterations per step** — Default 3, configurable via `maxIterations` or `-n` flag. Set `0` for unlimited. If still failing after N attempts: if `failOnError` is true, abort; otherwise escalate to the user with remaining issues.
6. **Scope per step** — Correctness and adversarial: only the changed files. Impact: the changed files + their dependents found via search.
7. **Deliver with summary** — After all stages pass, report: what was reviewed, iteration counts per stage, what was fixed, how many dependents were checked.

## Example Output

```
Codex Review Pipeline: PASS

Correctness (1 iteration):
- Fix 1: null guard on updateRow — cell could be undefined after re-render

Impact Analysis (1 iteration):
- Checked 7 dependent files using TabulatorCellFormatter
- lokal_penjualan/list_formatter_dibagikan.js — SAFE (uses updateRow, now guarded)
- lokal_returan_customer/list_formatter_dibagikan.js — SAFE (same pattern)
- 5 other formatters — SAFE (do not use updateRow)

Adversarial (2 iterations):
- Fix 1: concurrent renderComplete fires could double-run fetch
- Fix 2: empty result.data array — setDefaultValue called on stale $els

All fixes applied. Ready to test.
```
