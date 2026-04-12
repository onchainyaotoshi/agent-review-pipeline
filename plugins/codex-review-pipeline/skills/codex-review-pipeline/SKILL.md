---
name: codex-review-pipeline
description: 2-stage code review pipeline (correctness + adversarial) via Codex — run when user asks to review, check, or validate code before commit
argument-hint: "[files or scope to review]"
---

# Codex Review Pipeline

Run a multi-stage review until the code is ready to ship. Fully automatic — no manual trigger per stage.

## Prerequisites

This skill requires the **Codex plugin** (`codex:codex-rescue` subagent). Install it first:

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
```

If the Codex plugin is not installed, inform the user and stop.

## When to Use

- **Only when the user asks** — "review", "check this", "run the pipeline", "make sure this is correct"
- Or when the user asks to commit — run before committing
- **DO NOT** run automatically after every coding session — the user may want to test and approve first.

## Pipeline

```
┌─────────────────┐
│  1. CODEX REVIEW │ ← check logic, null checks, column counts, missing functions
│    (correctness) │
└────────┬────────┘
         │ issues? → fix → retry step 1
         │ PASS ↓
┌─────────────────┐
│ 2. CODEX ADVERSARIAL │ ← try to break: edge cases, data loss, double-count,
│    (break it)        │   stale state, race conditions, missing validation
└────────┬────────┘
         │ issues? → fix → retry step 2
         │ PASS ↓
┌─────────────────┐
│   3. DELIVER     │ ← hand off to user with summary:
│                  │   "Codex Review PASS, Adversarial PASS"
└─────────────────┘
```

## How to Run

Use the `codex:codex-rescue` subagent with a stage-appropriate prompt:

### Step 1: Codex Review (Correctness)

```
"Review [files]. Check for: logic errors, null derefs, missing functions,
column/data mismatches, type mismatches, missing error handling.
Report PASS or list issues with file:line."
```

### Step 2: Codex Adversarial (Break It)

```
"ADVERSARIAL review [files]. Try to BREAK this code. Think like a hostile tester.
Construct failure scenarios: edge cases, data loss, double-counting, stale state,
race conditions, bypass validation, overflow, empty/null inputs.
Focus on ACTUAL BUGS that crash or produce wrong data.
Report each with severity (Critical/High/Medium/Low) and file:line."
```

## Rules

1. **Never skip adversarial** — A PASS on review does not mean the code is safe. Adversarial often catches bugs that review misses (e.g., grand total double-count, stale sync on blur).
2. **Fix inline** — If issues are found, fix them in place, then re-run the same step. Do not advance to the next step until the current one passes.
3. **Max 3 iterations per step** — If still failing after 3 fix attempts, stop and escalate to the user with a list of remaining issues.
4. **Scope per step** — Only include relevant files, not the entire codebase. More focused = more accurate review.
5. **Deliver with summary** — After both pass, tell the user: what was reviewed, iteration counts, what was fixed.

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
