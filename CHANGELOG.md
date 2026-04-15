# Changelog

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
