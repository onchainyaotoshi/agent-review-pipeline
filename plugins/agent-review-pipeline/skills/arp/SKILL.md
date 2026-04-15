---
name: arp
version: 5.0.0-rc5
description: Autonomous dual-engine code review pipeline. Asymmetric dispatch — Codex runs dual-framing (correctness + adversarial), Gemini runs /ce:review (compound engineering persona pipeline). Dedups by confidence, auto-fixes inline. Supports dry-run.
argument-hint: "[--dry-run] [-n N] [codex|gemini|both] [PR number | files]"
---

> **Status:** Release candidate (rc5). rc2 addressed 3 security issues from PR #1's first e2e run; rc3 refined the post-dispatch write-check and documented the empirically-dead flash fallback path; rc4 upgraded parse-error handling and shipped the integration-test-harness spec; rc5 adds explicit PR-comment redaction (API keys, JWTs, PEM key blocks, inline credentials, bearer tokens) with fail-closed behavior. See CHANGELOG.

# Agent Review Pipeline (`/arp`)

Autonomous code review pipeline with dual-engine consensus, asymmetric dispatch (Codex dual-framing + Gemini `/ce:review`), bounded auto-fix loop, and loop-thrash protection. Pure review — regression verification is the CI's job.

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
| `gemini` | `Bash` tool | `timeout 600 gemini -m "<geminiModel>" --approval-mode yolo --include-directories ~/.gemini/commands/ce -p "$(cat .arp_stage_prompt.md)" -o text` — guarded by pre-dispatch `<ref>` validation + post-dispatch `git status` write-check | Delegated: `/ce:review` runs Gemini's compound-engineering multi-persona pipeline internally |

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
      "fingerprint": "<sha1(file+line+severity+normalized_issue+sha1(fix_code[:200]))>",
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
  "fingerprints_seen": ["<sha1>", "..."],
  "redactions": {
    "redactions_applied": 2,
    "kinds": ["api-key", "credential"]
  },
  "parse_errors": [
    {
      "source": "gemini:ce-review",
      "iteration": 2,
      "artifact": ".arp_parse_error_gemini-ce-review_iter2_1713195845.txt",
      "raw_bytes": 4823,
      "raw_sha1": "<sha1>",
      "first_200_chars": "..."
    }
  ]
}
```

- `fingerprint` = `sha1(file + ":" + line + ":" + severity + ":" + normalize(issue) + ":" + sha1(fix_code[:200]))`. `normalize` = lowercase + collapse whitespace + strip non-alphanumeric punctuation + trim. Severity and fix_code-hash prevent same-line distinct-bug collisions. Compute via bash helper: `normalize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/ /g; s/[^a-z0-9 ]//g' | sed 's/^ //; s/ $//'; }` then `printf '%s:%s:%s:%s:%s' "$file" "$line" "$severity" "$(normalize "$issue")" "$(printf '%.200s' "$fix_code" | sha1sum | cut -c1-40)" | sha1sum | cut -c1-40`.
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
4. **Concurrency guard:** acquire an advisory file lock via `exec 9>.arp.lock && flock -n 9` at pipeline start. If the lock cannot be acquired, abort with *"Another ARP run is in progress. Wait for it to finish or remove `.arp.lock` after confirming no other process."*. The lock is released automatically when the shell exits, or explicitly via `flock -u 9` at the end of Step 2. This is a real kernel-level lock — no TOCTOU window.
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

**Model cascade** — try `<geminiModel>` (default `gemini-3.1-pro-preview`), on `429`/quota error fall back to `gemini-2.5-pro`. **Fallback to `gemini-2.5-flash` is gated and discouraged**: only allowed when env `ALLOW_FLASH_FALLBACK=1` is set, otherwise abort dispatch with *"Gemini pro-tier exhausted (3.1-pro-preview + 2.5-pro); set ALLOW_FLASH_FALLBACK=1 to attempt flash (empirically unreliable for /ce:review — 2026-04-15 probes showed 10-min silent hang or polite quota-exhausted exit with 0 findings) or retry later"*. This prevents silent quality downgrade when an attacker or ambient usage exhausts pro quota. Per-model dispatch uses `timeout 600` (10 min) — on timeout SIGTERM the subprocess and move to the next cascade step.

**`<ref>` validation** — before interpolation, validate against `^[A-Za-z0-9/_.-]+$`. Reject with *"Invalid ref: <ref>"* if it contains quotes, newlines, or shell metacharacters. Prevents shell injection through attacker-controlled branch/PR refs.

**Prompt body** — written to `.arp_stage_prompt.md` first (so the shell never sees the prompt as an argv), then read via `$(cat .arp_stage_prompt.md)`:

```
/ce:review mode:report-only base:<ref>

After the compound-engineering review, output ONLY a JSON array summarizing all findings. No markdown fences, no prose.
Map severity: P0→critical, P1→high, P2→medium, P3→low.
Schema: [{"file":"...","line":12,"severity":"...","confidence":0.85,"issue":"...","fix_code":"..."}]
```

**Dispatch wrapper** (pre- and post-checks enforce read-only):

```bash
# 1. Validate <ref> to block shell/prompt injection
REF="<ref>"
[[ "$REF" =~ ^[A-Za-z0-9/_.-]+$ ]] || { echo "Invalid ref: $REF"; exit 1; }

# 2. Snapshot git state for post-dispatch write detection.
#    Excludes gitignored files (legit runtime artifacts like .arp_* cannot false-positive);
#    still catches modified tracked files and newly-created non-ignored files.
snapshot_git() {
  git rev-parse HEAD 2>/dev/null
  git diff HEAD 2>/dev/null | sha1sum
  git ls-files --others --exclude-standard 2>/dev/null | sort
}
GIT_BEFORE=$(snapshot_git)

# 3. Dispatch — yolo approval + narrowed include-dir + hard timeout
timeout 600 gemini -m "<geminiModel>" --approval-mode yolo \
  --include-directories "$HOME/.gemini/commands/ce" \
  -p "$(cat .arp_stage_prompt.md)" -o text

# 4. Post-dispatch write check — aborts pipeline if Gemini modified tracked files
#    or created new non-ignored files.
GIT_AFTER=$(snapshot_git)
[[ "$GIT_BEFORE" == "$GIT_AFTER" ]] || { echo "Gemini write detected despite mode:report-only — aborting"; exit 2; }
```

> Read-only enforced through **three layers**: (1) `mode:report-only` prompt flag, (2) `--include-directories` scoped to `~/.gemini/commands/ce` (not the whole `~/.gemini` tree — prevents credential exposure via `settings.json` MCP env/headers), (3) post-dispatch snapshot diff (tracked-file changes + new non-ignored files) that aborts on any modification. Gitignored paths (e.g. `.arp_*` runtime artifacts, any future `.gemini/` workspace cache) are deliberately excluded so legitimate runtime state cannot false-positive the check. `--approval-mode yolo` is necessary because `plan` blocks shell access which `/ce:review` needs for git/grep.

`<ref>` is the PR number or branch/ref passed to `/arp`. If reviewing local file paths, pass `HEAD` and include the list of paths in the prompt body.

**Parallel execution:** dispatch all active subagents concurrently. Collect outputs.

**JSON Robustness:**
1. On parse failure per dispatch, strip outer markdown fence (``` / ```json) if present and re-parse.
2. On second failure, persist the raw output to `.arp_parse_error_<source>_iter<N>_<epoch>.txt` (e.g. `.arp_parse_error_gemini-ce-review_iter2_1713195845.txt`) and record a diagnostics object in the session log's `parse_errors` array:
   ```json
   { "source": "gemini:ce-review", "iteration": 2, "artifact": ".arp_parse_error_gemini-ce-review_iter2_1713195845.txt", "raw_bytes": 4823, "raw_sha1": "<sha1>", "first_200_chars": "..." }
   ```
   Do not embed the full raw output in the session log (keeps the log lean and redactable). Skip that dispatch's findings for this iteration. Do not abort pipeline.
3. The Step 2 Deliver summary MUST surface parse-error counts per source (e.g. *"Dispatch health: Codex 2/2 OK, Gemini 0/1 (parse error — see `.arp_parse_error_gemini-ce-review_iter1_*.txt`)"*), so reviewers can tell a zero-finding run apart from a silent-skip run.
4. Parse-error artifacts are gitignored (`.arp_parse_error_*` glob added to `.gitignore`) and pruned alongside session logs after 7 days in Step 2 cleanup.

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
   - Per-source parse-error count with artifact path (e.g. *"gemini:ce-review — 1 parse error, raw at `.arp_parse_error_gemini-ce-review_iter1_*.txt`"*). Do not silent-skip.
2. Print summary to stdout always.
3. If `dryRun: true`: stop — do not commit, do not post.
4. If `autoCommit: true`: execute `git add .` and `git commit -m "chore(arp): autonomous review fixes"`. Off by default.
5. If `postPrComment: true`: scrub the executive summary body for secrets/PII (see **Redaction** below), then post to GitHub PR via `gh pr comment`. Off by default. **Fail-closed:** if the scrubber errors or matches a pattern but cannot replace it, abort the post and print the failure — never publish raw on a redaction failure.

   **Redaction patterns** (case-insensitive where applicable, applied per-line):
   - API keys: `sk-[A-Za-z0-9]{20,}`, `sk-ant-[A-Za-z0-9_-]{20,}`, `ghp_[A-Za-z0-9]{36}`, `gho_[A-Za-z0-9]{36}`, `ghu_[A-Za-z0-9]{36}`, `ghs_[A-Za-z0-9]{36}`, `glpat-[A-Za-z0-9_-]{20,}`, `xox[abprs]-[A-Za-z0-9-]{10,}`, `AKIA[0-9A-Z]{16}`, `ASIA[0-9A-Z]{16}` → `[REDACTED-API-KEY]`
   - JWT-shaped: `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}` → `[REDACTED-JWT]`
   - PEM private keys: any line starting with `-----BEGIN ` and ending with ` PRIVATE KEY-----` (and following lines until the matching `-----END ...-----`) → `[REDACTED-PRIVATE-KEY-BLOCK]`
   - Inline credential assignment in code snippets: `(?i)(password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|private[_-]?key)\s*[:=]\s*["']?([^"'\s,;]{6,})["']?` → preserve the LHS, replace value with `[REDACTED-CREDENTIAL]`
   - Bearer tokens in headers: `Bearer\s+[A-Za-z0-9._\-+/=]{16,}` → `Bearer [REDACTED-BEARER]`

   **Telemetry:** record `{ "redactions_applied": <int>, "kinds": ["api-key", "credential", ...] }` in the session log under a top-level `redactions` field. If `redactions_applied > 0`, append a footer to the PR comment body: *"> Note: N strings matching secret-pattern heuristics were redacted from this comment. The original session log is kept locally (gitignored) for human review."*

   **Scope note:** redaction applies to the PR comment body only. Local session logs and `.arp_parse_error_*.txt` artifacts are gitignored and may contain raw model output including any secrets the reviewer model echoed back — treat them as sensitive (don't paste, don't upload). A future runtime-rewrite branch should also scrub these on disk; spec'd here so callers know the current threat model.
6. Clean up `.arp_stage_prompt.md` and release the lock via `flock -u 9` (then `rm -f .arp.lock`). Rename `.arp_session_log.json` to `.arp_session_log.<timestamp>.json`. Prune `.arp_session_log.*.json` and `.arp_parse_error_*.txt` older than 7 days from the repo root to prevent unbounded growth.

## Safety Rails

- `maxIterations` clamped to **1-10**. Unlimited loops not supported.
- `autoCommit` and `postPrComment` default to `false`. User opts in.
- `--dry-run` disables all state-changing actions (Edit, commit, PR comment).
- Dependency precheck fails fast before any engine is dispatched.
- Parse errors persisted to `.arp_parse_error_<source>_iter<N>_<epoch>.txt` and surfaced per-source in the Deliver summary. Not fatal, but no longer silent-skipped.
- Codex dispatches prefix prompt with **"READ-ONLY review. Do not edit any file"** to prevent Codex from auto-editing in parallel with ARP orchestrator.
- Gemini read-only enforced via **three-layer defence**: `mode:report-only` prompt flag, `--include-directories` scoped to `~/.gemini/commands/ce` only (not `~/.gemini`), and post-dispatch snapshot diff (tracked-file changes + new non-ignored files) that aborts on any modification. Gitignored runtime artifacts are deliberately excluded so legitimate state cannot false-positive the check. `--approval-mode yolo` is needed because `plan` blocks the shell access `/ce:review` requires.
- PR comment body scrubbed for API keys, JWT-shaped tokens, PEM private-key blocks, inline credential assignments, and bearer tokens before posting (see Step 2.5). Fail-closed: scrubber error or unreplaceable match aborts the post rather than publishing raw.
- `<ref>` validated against `^[A-Za-z0-9/_.-]+$` before interpolation — blocks shell/prompt injection through attacker-controlled branch or PR refs.
- Model cascade fallback to `gemini-2.5-flash` requires explicit `ALLOW_FLASH_FALLBACK=1` env — prevents silent review-quality downgrade when pro-tier quota is exhausted (by attacker or ambient usage).
- Per-model Gemini dispatch has a 10-minute `timeout 600` watchdog. On timeout, SIGTERM and move to next cascade step.
- Concurrency guard uses real `flock -n` advisory lock on `.arp.lock`, not an mtime sniff — no TOCTOU window.

## Tuning Notes

- **Agreement rate < 0.3** sustained → engines disagree often, dual-engine is paying its cost. Keep `defaultEngine: both`.
- **Agreement rate > 0.9** sustained → engines usually agree, dual-engine is largely wasted spend. Consider `defaultEngine: codex` (or `gemini`) + raise confidence threshold to 0.75.
- **Codex adversarial contribution < 10% of unique findings** → the adversarial framing on Codex isn't adding value beyond correctness + ce:review. Consider dropping to single Codex framing (halve Codex cost).
- **Escalation rate rising** → LLM keeps proposing the same non-working fix, or the repo has a legitimately tricky area. Inspect escalated fingerprints before increasing `maxIterations`.
- **Regression verification is out of scope.** Rely on CI / existing test suite to catch any regression.
