# Changelog

## 5.0.0-rc11 — 2026-04-15

Reverts rc10's broken model-name change while keeping its correct cascade simplification.

### Background

rc10 renamed `gemini-3.1-pro-preview` → `gemini-3.1-pro` and `gemini-2.5-flash` → `gemini-3-flash` based on names visible in the Gemini CLI's interactive model-selector UI. **The names visible in that UI are display labels for Auto mode, not valid headless API model IDs.** Verified empirically right after the rc10 dispatch:

- `gemini -p ... -m gemini-3.1-pro` → `404 ModelNotFoundError: Requested entity was not found.`
- `gemini -p ... -m gemini-3-flash` → same 404
- `gemini -p ... -m gemini-3.1-pro-preview` → 429 backoff path (still valid, just rate-limited)

So the `-preview` suffix is part of the canonical headless model ID, even though the interactive Auto-mode UI renders it without.

### Changed

- **`geminiModel` default**: reverted `gemini-3.1-pro` → `gemini-3.1-pro-preview` in `plugin.json` and SKILL.md.
- **Flash fallback model**: reverted `gemini-3-flash` → `gemini-2.5-flash` (the only valid headless Flash ID currently — Gemini-3 Flash is display-only).
- **Cascade**: stays as rc10's simplified `gemini-3.1-pro-preview → (gated) gemini-2.5-flash` two-hop. rc10's reasoning for dropping the redundant `gemini-2.5-pro` hop (same Pro quota bucket) was correct and is preserved.
- **README + SKILL.md added a "Headless model-ID note"**: explicitly documents that Auto-mode UI labels and headless `-m` IDs are different namespaces. Verify with `gemini models list` before changing.

### Lesson

UI-visible model names ≠ headless API model IDs. Always probe with `gemini -p ... -m <id> -p "ping"` before pinning a new name, even when the UI shows it as canonical.

## 5.0.0-rc10 — 2026-04-15

Model naming + cascade simplification driven by user inspection of Gemini CLI's quota dashboard.

### Background

The Gemini CLI model-selector reveals three separate quota buckets — **Pro**, **Flash**, **Flash Lite** — each with its own daily cap and per-minute rate limit. It also shows the canonical model names: `gemini-3.1-pro` and `gemini-3-flash` (no `-preview` suffix). The `-preview` variant we'd been pinning is a legacy alias.

Our rc1-rc9 cascade (`gemini-3.1-pro-preview → gemini-2.5-pro → ALLOW_FLASH_FALLBACK gemini-2.5-flash`) had three issues:

1. Used the legacy `-preview` alias instead of the canonical name.
2. The `gemini-2.5-pro` fallback hop was useless — it shares the **Pro bucket** with `gemini-3.1-pro`, so a Pro-bucket exhaustion fails both at the same time.
3. Flash fallback to `gemini-2.5-flash` jumped families. Stay in Gemini-3 by using `gemini-3-flash` for consistency in tokenization, prompt interpretation, and behavior.

### Changed

- **`geminiModel` default**: `gemini-3.1-pro-preview` → `gemini-3.1-pro` in `plugin.json` userConfig and SKILL.md.
- **Cascade simplified**: `gemini-3.1-pro` → (gated) `gemini-3-flash`. Two hops instead of three. `gemini-2.5-pro` removed — it's redundant when both share the Pro bucket.
- **Flash fallback model**: `gemini-2.5-flash` → `gemini-3-flash`. Stays in the Gemini-3 family.
- **Abort message updated**: "Gemini Pro bucket exhausted" replaces "Gemini pro-tier exhausted (3.1-pro-preview + 2.5-pro)" since there's no `+ 2.5-pro` step anymore.
- **README**: `geminiModel` row in plugin README now documents the cascade in the description column.

### Notes

- `-preview` may still work as an alias today, but pinning the canonical name protects against the alias being removed.
- 2026-04-15 quota event was a per-minute rolling-window 429 (Gemini reported "1h32m" reset), not the daily-cap 23h+ reset visible in the model-selector. Both limits exist; the rolling-window one is what hit us today.

## 5.0.0-rc9 — 2026-04-15

Closes a "second-run-on-stale-diff" foot-gun surfaced by user trace-through.

### Background

`gh pr diff <n>` returns the GitHub-side PR HEAD, not the local working tree. If a prior `/arp` run applied auto-fixes (Edit calls) but left them uncommitted (autoCommit=false default), a second run would:

1. Fetch the same stale PR diff (because PR HEAD didn't change).
2. Re-surface the same findings (loop-thrash kill switch doesn't help — `fingerprints_seen` is fresh per session and doesn't persist cross-run).
3. Auto-fix loop tries to Edit the same `old_string` — which is already the *new* string in the local file — failing mid-loop with "old_string not found" and corrupting downstream iteration accounting.

### Added

- **Pre-flight working-tree freshness check** (Step 0.5). Runs `git diff --quiet HEAD` and `git diff --cached --quiet`; if either is non-clean, abort with a triage-friendly message listing the four resolution paths (`git status` / commit+push / `git stash` / `--dry-run`). Skipped under `--dry-run` because peek mode applies no edits, so dirty-tree second runs are harmless. Untracked files do NOT trigger the check (irrelevant to dispatch diff).

### Result

`/arp 1` after a previous-run-with-uncommitted-fixes now fails fast with explicit guidance instead of silently re-reviewing a stale diff and corrupting the auto-fix loop. Quota is preserved; user is told exactly which command to run next.

## 5.0.0-rc8 — 2026-04-15

User-feedback simplification of the argument surface.

### Breaking

- **File-path review removed.** `/arp src/foo.ts src/bar/` is no longer accepted. PR is now the sole review target. Rationale: the user's actual workflow is PR-only — file-path mode added flag-parsing and target-resolution branching for a path nobody used. Removing simplifies SKILL.md, plugin.json arg hint, and both READMEs.
- **`/arp` (no args) now auto-detects the open PR for the current branch** via `gh pr view --json number -q .number`. If no PR exists, abort with *"No PR found for current branch — push and open a PR first, or pass a PR number explicitly"*. Behavior previously implied "review current diff" which conflated with file-path mode.
- **`gh auth status` is now always run in pre-flight**, not gated on "if a PR number was passed". Since PR is the only target, `gh` auth is mandatory.

### Result

`argument-hint` shrank from `[--dry-run] [-n N] [codex|gemini|both] [PR number | files]` to `[--dry-run] [-n N] [codex|gemini|both] [PR number]`. Step 0.1 flag-parsing simpler. Step 0.6 PR-resolution no longer branches. README usage examples cleaner.

## 5.0.0-rc7 — 2026-04-15

Closes the on-disk artifact-scrub blocker introduced as a narrower follow-up in rc5. Reuses the rc5 scrubber pattern set at two new write points.

### Added

- **Parse-error artifact scrubbing at write-time.** Before persisting raw dispatch output to `.arp_parse_error_*.txt`, run the rc5 scrubber over the content (API keys, JWTs, PEM blocks, inline credentials, bearer tokens). Artifacts are diagnostic-only — no downstream code reads them — so write-time scrubbing is the simplest correct point.
- **Session log scrubbing on rotation.** In Step 2.6 cleanup, scrub `.arp_session_log.json` string values (file paths, issue text, fix_code) before renaming to `.arp_session_log.<timestamp>.json`. The active log stays raw during the run because kill-switch fingerprint matching reads it back; the archived copy is scrubbed so secret material does not accumulate across runs.
- **Fail-closed at every scrub point.** Scrubber error during artifact write or log rotation aborts the action rather than writing/archiving raw, matching Step 2.5 semantics.

### Result

The rc5 scope-note caveat ("future runtime-rewrite branch should also scrub these on disk") is closed in prompt-form. Remaining attack surface is in-memory dispatch buffers between scrub points, which truly does require a runtime rewrite to address — narrowed in CONTRIBUTING.

### Still known-open

- Deterministic fingerprint across Claude sessions (LLM-dependent `normalize(issue)` text)
- LLM-side cost pre-estimate
- In-memory dispatch buffer scrubbing (narrowed from on-disk scrub)
- Integration test harness implementation (spec at `docs/specs/integration-test-harness.md`)
- `/ce:review` `-p` headless reliability (external — Gemini CLI / quota)

## 5.0.0-rc6 — 2026-04-15

Closes the enforced-Codex-read-only blocker. Continues the same-day rc cycle while quota recovers.

### Background

`codex-rescue`'s own agent definition states: *"Default to a write-capable Codex run by adding `--write` unless the user explicitly asks for read-only behavior or only wants review, diagnosis, or research without edits."* rc1-rc5 relied solely on a "READ-ONLY review. Do not edit any file" prompt prefix — defensible but not provably enforced, since the agent could choose to interpret the request weakly and still pass `--write`.

### Added

- **Codex shared read-only contract.** Both Codex dispatches (correctness + adversarial) now share a verbatim-aligned read-only prefix using `codex-rescue`'s own recognition phrasing (*"review only, no edits"* + explicit *"do not pass `--write` to `codex-companion`"*). This matches the agent's selection-guidance trigger so the default `--write` flag is skipped.
- **Codex post-dispatch snapshot diff.** The same `snapshot_git` helper used for Gemini (rc3) is now wrapped pre/post each Codex Agent call. Divergence aborts with source-attributed message *"Codex write detected despite read-only contract — aborting"* (exit 2). Per-dispatch wrapping means the violator (correctness vs adversarial) is identifiable from the abort message.

### Result

Codex enforced read-only is now defended at two independent layers — prompt-level (matches agent's own recognition phrasing) plus repo-state snapshot diff (catches violations regardless of prompt compliance). Removed from the open-blocker list.

### Still known-open

- Deterministic fingerprint across Claude sessions (LLM-dependent `normalize(issue)` text)
- LLM-side cost pre-estimate
- On-disk scrubbing for session logs and parse-error artifacts
- Integration test harness implementation (spec at `docs/specs/integration-test-harness.md`)
- `/ce:review` `-p` headless reliability (external — Gemini CLI / quota)

## 5.0.0-rc5 — 2026-04-15

Closes the PR-comment redaction blocker. Continues the same-day rc cycle while quota recovers.

### Added

- **PR-comment scrubber** (Step 2.5). Before posting the executive summary via `gh pr comment`, redact:
  - API keys: `sk-*`, `sk-ant-*`, `ghp_*`, `gho_*`, `ghu_*`, `ghs_*`, `glpat-*`, `xox[abprs]-*`, `AKIA*`, `ASIA*` → `[REDACTED-API-KEY]`
  - JWT-shaped tokens (`eyJ...` 3-segment) → `[REDACTED-JWT]`
  - PEM private-key blocks (multi-line `-----BEGIN ... PRIVATE KEY----- … -----END ...-----`) → `[REDACTED-PRIVATE-KEY-BLOCK]`
  - Inline credential assignments (`password|secret|api_key|access_key|auth_token|private_key = "..."`) → preserve LHS, replace value with `[REDACTED-CREDENTIAL]`
  - Bearer tokens (`Bearer <16+ chars>`) → `Bearer [REDACTED-BEARER]`
- **Fail-closed behavior:** scrubber error or unreplaceable match aborts the post — never publishes raw on a redaction failure.
- **Telemetry:** `redactions: { redactions_applied, kinds[] }` field added to session log schema. When `redactions_applied > 0`, a footer line is appended to the PR comment so reviewers know the body was modified.
- **Threat-model note:** local session logs and `.arp_parse_error_*.txt` artifacts are NOT scrubbed — they're gitignored and may contain raw model output. Documented as sensitive; future runtime-rewrite branch should scrub on disk.

### Fixed

- **Safety Rails Gemini bullet drift.** rc3 changed the post-dispatch write-check from `git status --porcelain` to a snapshot-diff approach, but the Safety Rails section was never updated and still cited the old mechanism. Now matches the canonical wrapper pseudocode.

### Still known-open

- Deterministic fingerprint across Claude sessions (LLM-dependent `normalize(issue)` text)
- Integration test harness implementation (spec at `docs/specs/integration-test-harness.md`)
- `/ce:review` `-p` headless reliability (hang observed on 2.5-flash in PR #1 run)
- Enforced Codex read-only (prompt-level only; codex-rescue may still pass `--write`)
- LLM-side cost pre-estimate

## 5.0.0-rc4 — 2026-04-15

Quota-wait productivity pass — tackles two named production blockers without burning dispatch quota.

### Changed

- **Parse-error diagnostics upgraded from silent-skip to explicit per-source artifacts.** On second JSON parse failure, the raw dispatch output is now persisted to `.arp_parse_error_<source>_iter<N>_<epoch>.txt` and the session log records a diagnostics object (`source`, `iteration`, `artifact`, `raw_bytes`, `raw_sha1`, `first_200_chars`). The Deliver summary MUST surface per-source parse-error counts with the artifact path — reviewers can now distinguish a zero-finding run from a silent-skip run. Artifacts are gitignored and pruned alongside session logs after 7 days.
- **Session log schema extended** with a `parse_errors` array (see SKILL.md schema block).

### Added

- `docs/specs/integration-test-harness.md` — draft spec for deterministic fixture-replay harness (named production blocker). Captures interception-point options, fixture layout, coverage matrix, CI plan, and open questions. Not implemented yet; unblocks the follow-up PR.

### Docs

- `CONTRIBUTING.md` fingerprint formula synced to rc2+ (`sha1(file:line:severity:normalize(issue):sha1(fix_code[:200]))`) — the "Design Principles" bullet was still citing the rc1 formula.
- `.arp_parse_error_*.txt` added to `.gitignore`.

### Still known-open

- Deterministic fingerprint across Claude sessions (LLM-dependent `normalize(issue)` text)
- PR comment redaction for secrets/PII
- Integration test harness (**spec landed, implementation deferred**)
- `/ce:review` `-p` headless reliability (hang observed on 2.5-flash in PR #1 run)
- Enforced Codex read-only (prompt-level only; codex-rescue may still pass `--write`)

## 5.0.0-rc3 — 2026-04-15

Two refinements surfaced by a same-day validation-probe pass against the Gemini fork:

### Fixed

- **Post-dispatch write-check no longer false-positives on gitignored runtime artifacts.** The rc2 check snapshot `git status --porcelain`, which flags every untracked file — so a harmless artifact like `.arp_*` or a Gemini workspace cache could abort the pipeline even though the actual repo state was clean. Snapshot now uses `git rev-parse HEAD`, `git diff HEAD | sha1sum`, and `git ls-files --others --exclude-standard`. Gitignored paths (legit runtime state) are deliberately excluded; tracked-file modifications and new non-ignored files are still caught.

### Documented

- **Flash fallback is empirically dead for `/ce:review`.** 2026-04-15 probes: flash with slash-form prompt hung silent for 10 min producing 0 bytes; flash with natural-language prompt exited clean at 5m46s with a polite "quota exhausted, unable to complete" (363 bytes, no findings). The `ALLOW_FLASH_FALLBACK=1` gate from rc2 stays — strengthened abort message now cites this evidence so operators don't flip the gate expecting a usable review.

## 5.0.0-rc2 — 2026-04-15

Addresses the 7 findings from the first end-to-end validation run (PR #1), 3 of which were critical/high security issues introduced by rc1's Gemini dispatch hardening. Still rc — `/ce:review` under `-p` headless mode remains a known reliability risk (observed in the PR #1 run: the dispatch hung 41 min on `gemini-2.5-flash` and was SIGTERMed).

### Security fixes

- **Narrow `--include-directories`** from `~/.gemini` to `~/.gemini/commands/ce`. Prior scope granted Gemini read on `~/.gemini/settings.json` which can hold MCP env / headers (API keys). [P0 critical, conf 0.91 — Codex adversarial]
- **Post-dispatch write check** — snapshot `git rev-parse HEAD && git status --porcelain` before and after each Gemini call; any delta aborts the pipeline. Catches writes that slip past `mode:report-only` when the model is prompt-injected or malfunctions. [P0 critical, conf 0.94 — Codex adversarial]
- **`<ref>` validation** — reject branch/PR refs not matching `^[A-Za-z0-9/_.-]+$` before interpolating into the prompt. Blocks shell/prompt injection via attacker-controlled branch names. [P1 high, conf 0.83 — Codex adversarial]

### Reliability / hardening

- **`flock` concurrency guard** — replaced 10-min mtime sniff with real advisory lock (`exec 9>.arp.lock && flock -n 9`). No more TOCTOU window between two concurrent `/arp` runs.
- **`ALLOW_FLASH_FALLBACK` gate** — cascade to `gemini-2.5-flash` now requires explicit opt-in env var. Pro-tier exhaustion no longer silently degrades review quality to flash.
- **`timeout 600` per Gemini model attempt** — prevents 41-minute hangs like the one observed in PR #1 run. On timeout, subprocess is SIGTERMed and the cascade advances.
- **Fingerprint formula tightened** — now includes `severity` and `sha1(fix_code[:200])` in the hash input. Two distinct bugs on the same line with similar issue text no longer collide and silently dedup.
- **Spec drift fixed** — architecture table (line 30) and Safety Rails (line 197) now match the actual yolo-mode Gemini dispatch instead of the deprecated `--approval-mode plan` wording.
- `.arp.lock` added to `.gitignore`.

### Still known-open (see Production Blockers in rc1 entry)

- Non-deterministic fingerprint across Claude sessions (LLM-dependent `normalize(issue)` text)
- Parse-error diagnostics beyond silent skip
- PR comment redaction for secrets/PII
- Integration test harness
- `/ce:review` `-p` headless reliability (hang observed on 2.5-flash in PR #1 run)
- Enforced Codex read-only (prompt-level only; codex-rescue may still pass `--write`)

### Validation

- PR #1 comment: https://github.com/onchainyaotoshi/agent-review-pipeline/pull/1#issuecomment-4249096309
- Dispatch health: Codex 2/2 OK, Gemini 0/1 (quota + flash hang)
- Will re-run `/arp` on this branch after Gemini quota recovers to confirm the patches hold.

## 5.0.0-rc1 — 2026-04-15

Release candidate for 5.0.0. Design and documentation complete; prompt-driven orchestration is **not** yet end-to-end tested against real Codex + Gemini dispatches. Treat behavior as contract, not guarantee.

### Breaking (vs 4.1.0)
- **Pipeline simplified from 5 stages to 2.** Impact Analysis and Test Generation stages removed. Caller/consumer checks are now part of Correctness framing. Regression verification is delegated to CI.
- **Stage structure:** `0. Context → 1. Review → 2. Deliver`.
- **Asymmetric dispatch.** Codex runs ARP's dual-framing (correctness + adversarial, 2 dispatches); Gemini runs its own `/ce:review` compound-engineering pipeline (1 dispatch). Total dispatches with `defaultEngine: both`: **3**.
- **Gemini dispatch via `gemini -p "/ce:review ..."`** through direct CLI. The prior `compound-engineering:review:ce-review` Claude-plugin subagent path is removed (dependency was never installed locally and not verifiable).
- **Safe-off defaults.** `autoCommit` and `postPrComment` default to `false`. Users must opt in.
- **`maxIterations` clamped to 1-10.** Unlimited (`0`) no longer supported — cost safety.
- **Default `geminiModel`** set to `gemini-3.1-pro-preview`.
- **Codex prompts prefixed** with "READ-ONLY review. Do not edit any file" to prevent Codex from auto-editing in parallel with the orchestrator (Gemini is hard-locked read-only via `--approval-mode plan`).
- **New prerequisite:** `/ce:review` Gemini extension (`~/.gemini/commands/ce/review.toml`). Precheck fails fast if missing.

### Added
- `--dry-run` / `-d` flag and `dryRun` userConfig option. Prints findings + proposed fixes without Edit, commit, or PR comment.
- `.arp_session_log.json` per-run session log with fingerprint tracking, agreement counters, parse-error log, and timestamped rotation (pruned after 7 days).
- **Loop-thrash kill switch.** Findings fingerprinted as `sha1(file:line:issue)`. A fingerprint reappearing after its fix was applied escalates to human review instead of looping.
- **Engine precedence rule.** CLI token > `defaultEngine` userConfig > hard default `both`.
- **`failOnError` semantics.** `true` aborts with non-zero exit when `maxIterations` hit with residual findings; `false` (default) promotes them to `ESCALATED` and proceeds to Deliver.
- **Expanded dependency precheck:** `codex:codex-rescue`, `gemini --version`, `gemini models list` validation of `geminiModel`, `~/.gemini/commands/ce/review.toml`, `gh auth status` (when reviewing PRs by number).
- **Concurrency guard.** Aborts if `.arp_*` artifacts were modified within the last 10 minutes.
- **JSON parse-error handling.** Malformed subagent output logged under `parse_errors` and skipped, not fatal.
- **Version field** in SKILL.md frontmatter for pinning.
- **`.gitignore`** for `.arp_*` runtime artifacts.
- **CONTRIBUTING.md** with project layout, doc-sync rules, and known production blockers.
- Agreement-rate telemetry and tuning notes in the plugin README.

### Removed
- Impact Analysis stage (merged into Correctness).
- Test Generation stage (delegated to CI).
- Holistic regression loop concept (no longer needed with single Review stage).
- Classify-and-route logic (`backend`/`frontend`/`neutral`/`skip`) and `.arp.json` project override.
- "N-stage" marketing language.

### Production Blockers (deferred to a future runtime-rewrite branch)
The following require moving from prompt-driven execution to an actual runtime orchestrator and cannot be fixed in the prompt-only skill:

- Deterministic fingerprint computation across Claude sessions
- Session log concurrency / file locking (current guard is soft detection only)
- Robust JSON parse-error diagnostics beyond silent skip
- Enforced Codex read-only (currently relies on prompt-level instruction; codex-rescue may still pass `--write`)
- Token cost pre-estimate
- PR comment redaction for secrets/PII
- LLM-normalize pass for fingerprint fuzziness
- End-to-end integration test harness
- `/ce:review` output-format verification under `-p` headless mode (JSON extraction untested)

See CONTRIBUTING.md for details on contributing fixes.

## 4.1.0 — 2026-04-14
- Upgrade to Dual-Engine Consensus and Holistic Review.

## 2.0.0
- Rename to `agent-review-pipeline`, add Gemini support, auto-routing by file domain.

## 1.x
- Initial releases as `codex-review-pipeline`, single-engine Codex reviewer.
