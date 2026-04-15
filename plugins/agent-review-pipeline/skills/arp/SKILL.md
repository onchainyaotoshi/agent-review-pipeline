---
name: arp
version: 5.0.0-rc1
description: Autonomous dual-engine code review pipeline. Asymmetric dispatch — Codex runs dual-framing (correctness + adversarial), Gemini runs /ce:review (compound engineering persona pipeline). Dedups by confidence, auto-fixes inline. Supports dry-run.
argument-hint: "[--dry-run] [-n N] [codex|gemini|both] [PR number | files]"
---

> **Status:** Release candidate. Design and documentation complete; prompt-driven orchestration has not been end-to-end tested against real Codex + Gemini dispatches. Treat behavior as contract, not guarantee. See CHANGELOG for the production-hardening backlog.

# Agent Review Pipeline (`/arp`)

Autonomous code review pipeline with dual-engine consensus, asymmetric dispatch (Codex dual-framing + Gemini `/ce:review`), bounded auto-fix loop, and loop-thrash protection. Pure review — regression verification is the CI's job.

<!-- test comment for ARP e2e validation -->

## Prerequisites

- **Codex plugin** installed: `/plugin install codex@openai-codex` (provides the `codex:codex-rescue` Agent).
- **Gemini CLI** installed and authenticated: verify with `gemini --version` and `gemini models list`.
- **Gemini `/ce:review` extension** installed — check `~/.gemini/commands/ce/review.toml` exists. Provides the compound-engineering review pipeline Gemini dispatches will use.
- **`gh` CLI** authenticated if reviewing PRs by number.

## Architecture — Asymmetric Engine Registry

Prompts are written to a temporary file `.arp_stage_prompt.md` to bypass OS argument-length limits.

| Engine | Dispatch | Target / Command | Framing |
|--------|----------|------------------|---------|
| `codex` | `Agent` tool | `codex:codex-rescue` subagent | ARP-controlled: runs **twice** — once per framing (correctness + adversarial) |
| `gemini` | `Bash` tool | `gemini -m "<geminiModel>" -p "/ce:review <args>\n\n<json output instruction>" --approval-mode plan -o text` | Delegated: `/ce:review` runs Gemini's compound-engineering multi-persona pipeline internally |

**Why asymmetric:** Gemini already has `/ce:review`, a structured multi-persona review pipeline with P0-P3 severity tiering. Running ARP-side dual-framing on top would be redundant. Codex has no equivalent, so ARP provides the dual-framing discipline for Codex via two separate dispatches.

**Total dispatches per iteration:**
- `defaultEngine: both` → **3** (codex × correctness, codex × adversarial, gemini × /ce:review)
- `defaultEngine: codex` → **2** (codex × correctness, codex × adversarial)
- `defaultEngine: gemini` → **1** (gemini × /ce:review)

## Session Log — `.arp_session_log.json`

Per-run session log for agreement-rate telemetry and loop-thrash detection. Schema:

```json
{
  "iteration": 1,
  "findings": [
    {
      "fingerprint": "<sha1(file+line+normalized_issue)>",
      "file": "...",
      "line": 12,
      "issue": "...",
      "severity": "high",
      "confidence": 0.93,
      "produced_by": ["codex", "gemini"],
      "source": ["codex:correctness", "gemini:ce-review"],
      "fix_code": "...",
      "applied": true
    }
  ],
  "agreement": {
    "codex_only": 2,
    "gemini_only": 1,
    "both": 5,
    "rate": 0.625
  },
  "fingerprints_seen": ["<sha1>", "..."]
}
```

- `fingerprint` = `sha1(file + ":" + line + ":" + issue.toLowerCase().trim())`. Compute via `bash: printf '%s' "text" | sha1sum | cut -c1-40`.
- `agreement.rate` = `both / (codex_only + gemini_only + both)`.
- `source` lists exact dispatch origin (`codex:correctness`, `codex:adversarial`, `gemini:ce-review`) for debugging.

## Pipeline Flow

```
   ┌────────────────────────────────────────────┐
   │ 0. Context Setup (entire PR)               │
   └──────────────────┬─────────────────────────┘
                      │
   ┌──────────────────▼─────────────────────────┐
   │ 1. Review — 3 parallel dispatches           │
   │    codex   × correctness framing (ARP)      │
   │    codex   × adversarial framing (ARP)      │
   │    gemini  × /ce:review (compound engin.)   │
   └──────────────────┬─────────────────────────┘
                      │ Merge + Fingerprint
                      │ multi-source? +0.15 boost (cap 1.0)
                      │ conf < 0.60? drop
                      │ fingerprint reappears? kill switch → escalate
                      │ Auto-fix → loop until PASS or max (cap 10)
                      ▼
   ┌────────────────────────────────────────────┐
   │ 2. Deliver — summary, agreement rate,       │
   │    optional git commit + gh pr comment      │
   └────────────────────────────────────────────┘
```

## How to Run

### Step 0: Context & Setup
1. **Flag parsing:** recognize `--dry-run` (or `-d`), `-n N` / `--max-iterations N` (clamp to 1-10), `codex|gemini|both`, PR number, file paths.
2. **Engine resolution (precedence order, first match wins):**
   - CLI token `codex`, `gemini`, or `both` passed to `/arp`
   - `defaultEngine` from `plugin.json` userConfig
   - Hard default: `both`
3. **Dependency precheck** (fail fast before any dispatch):
   - If `both` or `codex`: confirm `codex:codex-rescue` Agent exists. Error: *"Install Codex plugin: /plugin install codex@openai-codex"*.
   - If `both` or `gemini`:
     - Run `gemini --version`; error: *"Install gemini CLI and authenticate"*.
     - Run `gemini models list` and confirm `<geminiModel>` is listed; error: *"Model `<geminiModel>` not available. Run `gemini models list`."*.
     - Verify `~/.gemini/commands/ce/review.toml` exists; error: *"Install ce:review extension for Gemini"*.
   - If a PR number was passed: run `gh auth status`; error: *"Run `gh auth login` before reviewing PRs by number"*.
4. **Concurrency guard:** if `.arp_session_log.json` or `.arp_stage_prompt.md` exists and was modified within the last 10 minutes, abort with *"Another ARP run appears to be in progress. Delete `.arp_*` files to force a new run."*.
5. Scan repo root for `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `CONTRIBUTING.md`. Inject contents into the `<repository_rules>` block of every engine prompt.
6. Resolve PR targets via `gh pr diff <n>` (or use provided file paths).
7. Initialize `.arp_session_log.json` with empty findings.

### Step 1: Review (Asymmetric Dual-Engine)

Write prompt body to `.arp_stage_prompt.md`. The shared suffix is the JSON output schema:

> Respond with ONLY a JSON array. No markdown fences. No prose before or after.
> Schema: `[{"file":"...","line":12,"severity":"low|medium|high|critical","confidence":0.85,"issue":"...","fix_code":"..."}]`

**Dispatch 1 — Codex × Correctness framing** (Agent tool → `codex:codex-rescue`):

Prompt includes: "READ-ONLY review. Do not edit any file — output findings only. You are a senior code reviewer. Find logic errors, null derefs, type mismatches, missing error handling, and broken callers. If a changed function signature / exported API / schema is found in the diff, grep the repo for call sites NOT in the diff and verify each still works. Emit a finding per broken caller with `fix_code`." Append JSON schema suffix.

**Dispatch 2 — Codex × Adversarial framing** (Agent tool → `codex:codex-rescue`):

Prompt includes: "READ-ONLY review. Do not edit any file — output findings only. You are a red-team attacker trying to break this code. Find edge cases, race conditions, off-by-one bugs, security bypasses (injection, path traversal, auth skip, integer overflow), data loss scenarios, and concurrency hazards. Assume every input can be malicious. Emit a finding with `fix_code` per vulnerability." Append JSON schema suffix.

**Dispatch 3 — Gemini × /ce:review** (Bash tool):

Model cascade: try `<geminiModel>` (default `gemini-3.1-pro-preview`), on quota error fall back to `gemini-2.5-pro`, then `gemini-2.5-flash`. Use the first model that responds without a 429/quota error.

```bash
gemini -m "<geminiModel>" --approval-mode yolo --include-directories ~/.gemini -p "/ce:review mode:report-only base:<ref>

After the compound-engineering review, output ONLY a JSON array summarizing all findings. No markdown fences, no prose.
Map severity: P0→critical, P1→high, P2→medium, P3→low.
Schema: [{\"file\":\"...\",\"line\":12,\"severity\":\"...\",\"confidence\":0.85,\"issue\":\"...\",\"fix_code\":\"...\"}]" -o text
```

> `--approval-mode yolo` is required — `plan` mode blocks shell access and prevents ce:review from running git/grep. Report-only mode (`mode:report-only`) ensures Gemini never edits files even with yolo approval. `--include-directories ~/.gemini` allows Gemini to read skill files outside the project workspace.

`<pr-or-diff-ref>` is the PR number or branch/ref passed to `/arp`. If reviewing local file paths, pass `HEAD` and include the list of paths in the prompt body.

**Parallel execution:** dispatch all active subagents concurrently. Collect outputs.

**JSON Robustness:**
1. On parse failure per dispatch, strip outer markdown fence (``` / ```json) if present and re-parse.
2. On second failure, log the raw output under `parse_errors` in the session log and skip that dispatch's findings. Do not abort pipeline.

**Merge + Fingerprint:**
3. For each finding, compute `fingerprint`. Tag with `source` (e.g. `codex:correctness`) and infer `produced_by` from source prefix.
4. If the same fingerprint surfaces from multiple dispatches, merge into one finding; union `source` and `produced_by`; set `confidence = min(1.0, confidence + 0.15 * (sources - 1))`.
5. Drop findings with `confidence < 0.60`.
6. Update `agreement` counters (based on `produced_by` — engine identity, not source label).

**Loop-Thrash Kill Switch:**
7. Before applying fixes, for each finding check if its `fingerprint` is in `fingerprints_seen`. If yes, the prior fix did not resolve it. Mark `ESCALATED`, skip auto-fix, append to PR report as "needs human review", do not count against `maxIterations`.

**Auto-Fix (skip if `dryRun: true`):**
8. Apply `fix_code` via Edit tool. Mark `applied: true` and add fingerprint to `fingerprints_seen`.

**Loop:**
9. Re-run Step 1 until no non-escalated findings remain OR `iteration == maxIterations` (clamped to 1-10).
10. **`failOnError` branch:** when `iteration == maxIterations` and non-escalated findings remain:
    - If `failOnError: true` → abort pipeline with non-zero exit, print remaining findings, do NOT proceed to Step 2. `autoCommit` and `postPrComment` never fire.
    - If `failOnError: false` (default) → promote remaining findings to `ESCALATED` status, proceed to Step 2, summary flags the run as partially unresolved.
11. If `dryRun: true`, run one iteration only and print the findings report. Do not loop, do not auto-fix.

### Step 2: Deliver
1. Compile summary from `.arp_session_log.json`:
   - Iteration count
   - Findings by severity
   - Findings by source (Codex correctness / Codex adversarial / Gemini ce:review contribution)
   - **Agreement rate** (aggregate `agreement.rate`)
   - Escalated findings (kill switch triggered)
   - Per-engine attribution (`codex_only`, `gemini_only`, `both`)
   - Parse error count
2. Print summary to stdout always.
3. If `dryRun: true`: stop — do not commit, do not post.
4. If `autoCommit: true`: execute `git add .` and `git commit -m "chore(arp): autonomous review fixes"`. Off by default.
5. If `postPrComment: true`: post executive summary to GitHub PR via `gh pr comment`. Off by default.
6. Clean up `.arp_stage_prompt.md`. Rename `.arp_session_log.json` to `.arp_session_log.<timestamp>.json` and prune logs older than 7 days from the repo root to prevent unbounded growth.

## Safety Rails

- `maxIterations` clamped to **1-10**. Unlimited loops not supported.
- `autoCommit` and `postPrComment` default to `false`. User opts in.
- `--dry-run` disables all state-changing actions (Edit, commit, PR comment).
- Dependency precheck fails fast before any engine is dispatched.
- Parse errors logged and skipped, not fatal.
- Codex dispatches prefix prompt with **"READ-ONLY review. Do not edit any file"** to prevent Codex from auto-editing in parallel with ARP orchestrator. (Gemini is hard-locked read-only via `--approval-mode plan`.)

## Tuning Notes

- **Agreement rate < 0.3** sustained → engines disagree often, dual-engine is paying its cost. Keep `defaultEngine: both`.
- **Agreement rate > 0.9** sustained → engines usually agree, dual-engine is largely wasted spend. Consider `defaultEngine: codex` (or `gemini`) + raise confidence threshold to 0.75.
- **Codex adversarial contribution < 10% of unique findings** → the adversarial framing on Codex isn't adding value beyond correctness + ce:review. Consider dropping to single Codex framing (halve Codex cost).
- **Escalation rate rising** → LLM keeps proposing the same non-working fix, or the repo has a legitimately tricky area. Inspect escalated fingerprints before increasing `maxIterations`.
- **Regression verification is out of scope.** Rely on CI / existing test suite to catch any regression.
