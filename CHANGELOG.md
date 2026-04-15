# Changelog

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
