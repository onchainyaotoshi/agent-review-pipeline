# ARP Benchmark Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/arp benchmark <PR>` subcommand that runs Gemini Flash and Pro in parallel against a PR, scores findings by precision/depth/FP-rate, and prints a numeric comparison table.

**Architecture:** New `## Benchmark Mode` section appended to `SKILL.md` (prompt-based implementation — no runtime code). Benchmark runs two Gemini dispatches (Flash + Pro), scores the parsed findings, prints ASCII table, writes `.arp_benchmark_<epoch>.json`. No auto-fix, no commit, no PR comment.

**Tech Stack:** SKILL.md (Claude prompt spec), Gemini CLI (`gemini -m <model>`), `gh` CLI, `jq`, bash

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `plugins/agent-review-pipeline/skills/arp/SKILL.md` | Add benchmark section + update frontmatter (version → 5.4.0, argument-hint) |
| Modify | `plugins/agent-review-pipeline/README.md` | Add benchmark usage examples |
| Modify | `plugins/agent-review-pipeline/.claude-plugin/plugin.json` | Version bump 5.3.2 → 5.4.0 |

---

## Task 1: Probe Gemini Pro model ID

**Files:**
- Run: `scripts/probe-gemini.sh` (existing helper)

The spec says `gemini-3.1-pro-preview` for headless `-m` but this must be verified empirically before hardcoding it in SKILL.md. The UI label (`gemini-3.1-pro`) differs from the headless CLI ID.

- [ ] **Step 1: Run probe against candidate model IDs**

```bash
cd /home/firman/agent-review-pipeline
bash scripts/probe-gemini.sh gemini-3.1-pro-preview
```

Expected: exit 0 and a short text response if the model is available.

If exit 2 or 3 (capacity exhausted), note this in SKILL.md as a known quota risk. If exit 1 (unknown model), try without the `-preview` suffix:

```bash
bash scripts/probe-gemini.sh gemini-3.1-pro
```

- [ ] **Step 2: Record the confirmed model ID**

Write the working model ID in a comment at the top of the benchmark section. If neither ID works, note that Pro benchmark requires quota and cannot be run now — the spec text should still reference `gemini-3.1-pro-preview` as the intended target.

- [ ] **Step 3: Commit**

```bash
git add -p  # no file changes expected — this is a discovery step
# Only commit if a probe script was updated as a side-effect
```

---

## Task 2: Add benchmark section to SKILL.md + update frontmatter

**Files:**
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md` (lines 1-6 for frontmatter, append new section after line 528)

- [ ] **Step 1: Update frontmatter (version + argument-hint)**

In `SKILL.md`, change the frontmatter block at lines 1-6 from:

```yaml
---
name: arp
version: 5.3.2
description: Autonomous dual-engine code review pipeline. Asymmetric dispatch — Codex runs dual-framing (correctness + adversarial), Gemini runs /ce:review (compound engineering persona pipeline). Fetches PR conversation context (comments, reviews, unresolved threads) for cross-iteration continuity. Dedups by confidence, auto-fixes inline. Supports dry-run.
argument-hint: "[--dry-run] [-n N] [codex|gemini|both] [PR number]"
---
```

to:

```yaml
---
name: arp
version: 5.4.0
description: Autonomous dual-engine code review pipeline. Asymmetric dispatch — Codex runs dual-framing (correctness + adversarial), Gemini runs /ce:review (compound engineering persona pipeline). Fetches PR conversation context (comments, reviews, unresolved threads) for cross-iteration continuity. Dedups by confidence, auto-fixes inline. Supports dry-run. Benchmark mode: /arp benchmark <PR> compares Flash vs Pro findings quality.
argument-hint: "[--dry-run] [-n N] [codex|gemini|both] [benchmark] [PR number]"
---
```

- [ ] **Step 2: Append benchmark section at end of SKILL.md**

After the last line of `SKILL.md` (currently line 528 — `## Tuning Notes` section), append:

```markdown

## Benchmark Mode (`/arp benchmark <PR>`)

Compare Gemini Flash vs Pro findings quality on a specific PR. Read-only — no auto-fix, no commit, no PR comment.

**Trigger:** First positional arg is the literal string `benchmark`.

**PR number required.** Benchmark does not auto-detect the current branch PR. If PR number is omitted, abort with: *"Benchmark requires an explicit PR number: /arp benchmark \<PR\>"*. Validate PR number against `^[0-9]+$` (same as main flow Step 0.1).

### Benchmark Setup

Run Step 0 substeps with these modifications:
- **Skip** engine resolution (benchmark always dispatches Gemini only)
- **Skip** Codex dependency precheck
- **Skip** working-tree freshness check (benchmark applies no edits)
- **Run** Gemini dependency precheck (Step 0.3 Gemini branch), `gh` auth check, and concurrency guard (Step 0.4) normally
- **Run** repo-rules fetch (Step 0.6), diff fetch (Step 0.7), and PR context fetch (Step 0.8) normally — benchmark uses the same trusted-base-ref rules and PR context

Acquire per-worktree `.arp.lock` (fd 9) and PR-scoped lock (fd 8) as normal. Both released on exit.

### Flash Dispatch

Identical to Step 1 Dispatch 3 (Gemini × /ce:review) with these overrides:
- Model: `gemini-3-flash-preview`
- Prompt body: same template as Step 1 Dispatch 3 (including parallel-dispatch directive, EXT_SUMMARY, emphasis directive)
- `snapshot_git` pre/post (same read-only enforcement)
- Capture raw output as `FLASH_RAW`

### Pro Dispatch

Identical to Flash Dispatch with these overrides:
- Model: `gemini-3.1-pro-preview` (**empirical probe required before first run** — UI shows `gemini-3.1-pro` but headless `-m` ID may differ; run `scripts/probe-gemini.sh gemini-3.1-pro-preview` to verify. If probe exits non-0, abort benchmark with: *"Pro model unavailable — run scripts/probe-gemini.sh gemini-3.1-pro-preview to diagnose. Pro tier may be capacity-exhausted."*)
- Capture raw output as `PRO_RAW`

Both dispatches run sequentially (not in parallel) to avoid racing on shared `.arp_stage_prompt.md`.

### Parse

Parse `FLASH_RAW` and `PRO_RAW` per JSON Robustness rules (Step 1 JSON Robustness, steps 1-2). On parse failure per model, record `parse_failed: true` in the artifact for that model and treat as 0 findings for scoring. Do not abort benchmark on parse failure — report the parse failure in the output table.

### Score

Compute three metrics per findings set. All metrics are 0–1 floats (or `null` if parse failed).

**Precision** — fraction of findings with `confidence ≥ 0.80`:
```
precision = count(f where f.confidence >= 0.80) / total_findings
```
If `total_findings == 0`: `precision = null`.

**Depth** — average composite score per finding:
```
per_finding_depth = (body_long + has_location + has_fix) / 3
  body_long    = 1 if len(f.issue) > 100 else 0
  has_location = 1 if f.file is non-empty AND f.line is present else 0
  has_fix      = 1 if f.fix_code is non-empty else 0
depth = mean(per_finding_depth for all findings)
```
If `total_findings == 0`: `depth = null`.

**FP Rate** — fraction of findings with `confidence < 0.70` (lower is better):
```
fp_rate = count(f where f.confidence < 0.70) / total_findings
```
If `total_findings == 0`: `fp_rate = null`.

**Token estimate** — parse from Gemini CLI stdout if present (look for a line matching `Total tokens:` or similar metadata). If not found, set `est_tokens = null`.

### Verdict

```
if flash and pro both parse_failed:
    verdict = { flash: "PARSE FAILED", pro: "PARSE FAILED", note: "No findings to compare — check parse error artifacts" }
elif flash parse_failed:
    verdict = { flash: "PARSE FAILED", pro: "N/A", note: "" }
elif pro parse_failed:
    verdict = { flash: "N/A", pro: "PARSE FAILED", note: "" }
elif pro_precision > flash_precision + 0.10 AND pro_fp_rate < flash_fp_rate:
    verdict = { flash: "CHEAPER", pro: "MORE ACCURATE", note: "" }
elif abs(pro_precision - flash_precision) <= 0.10:
    verdict = { flash: "GOOD ENOUGH (cheaper)", pro: "COMPARABLE", note: "" }
else:
    verdict = { flash: "?", pro: "?", note: "INCONCLUSIVE — review .arp_benchmark_*.json" }
```

### Output

Print to stdout after both dispatches complete:

```
╔══════════════════════════════════════════════════╗
║  ARP Benchmark — PR #<N> (<owner>/<repo>)        ║
╠══════════════════════╦═══════════╦═══════════════╣
║ Metric               ║ Flash     ║ Pro           ║
╠══════════════════════╬═══════════╬═══════════════╣
║ Total findings       ║ <n>       ║ <n>           ║
║ Precision (≥0.80)    ║ <0.XX>    ║ <0.XX>        ║
║ Depth score          ║ <0.XX>    ║ <0.XX>        ║
║ Suspected FP rate    ║ <0.XX>    ║ <0.XX>        ║
║ Est. tokens used     ║ <N|N/A>   ║ <N|N/A>       ║
╠══════════════════════╬═══════════╬═══════════════╣
║ Verdict              ║ <verdict> ║ <verdict>     ║
╚══════════════════════╩═══════════╩═══════════════╝
```

Replace `<0.XX>` with 2-decimal float (e.g. `0.72`). Replace `null` scores with `N/A`. If INCONCLUSIVE, append the note on its own line below the table.

### Artifact

Unless `--dry-run` is passed, write `.arp_benchmark_<epoch>.json` where `<epoch>` is `date +%s`:

```json
{
  "pr": <N>,
  "repo": "<owner/name>",
  "timestamp": "<ISO8601>",
  "flash": {
    "model": "gemini-3-flash-preview",
    "parse_failed": false,
    "findings": [...],
    "scores": {
      "precision": 0.0,
      "depth": 0.0,
      "fp_rate": 0.0,
      "total_findings": 0,
      "est_tokens": null
    }
  },
  "pro": {
    "model": "gemini-3.1-pro-preview",
    "parse_failed": false,
    "findings": [...],
    "scores": {
      "precision": 0.0,
      "depth": 0.0,
      "fp_rate": 0.0,
      "total_findings": 0,
      "est_tokens": null
    }
  },
  "verdict": {
    "flash": "...",
    "pro": "...",
    "note": ""
  }
}
```

Apply secret redaction before writing (same five-pattern scrubber as Step 2.5 — API keys, JWT, PEM, inline credentials, bearer tokens). Fail-closed: if scrubber errors, abort artifact write rather than write raw content.

`.arp_benchmark_*.json` is gitignored (add glob to `.gitignore` in Task 3) and pruned after 7 days in Step 2 cleanup (add to existing prune command).

### Safety Constraints

- No auto-fix, no `git commit`, no `gh pr comment` in benchmark mode — ever.
- Both dispatches run `mode:report-only` with `snapshot_git` pre/post.
- `--dry-run` suppresses artifact write (dispatches still run, table still printed).
- Concurrency guard active (same flock as main flow).
- `<ref>` validated `^[A-Za-z0-9/_.-]+$` before interpolation.
- Secret redaction applied to artifact at write-time (fail-closed).
```

- [ ] **Step 3: Run to verify benchmark section is parseable**

Ask Claude: `/arp benchmark 251` in the camis_api_native project. If Claude responds with *"Benchmark requires an explicit PR number"* when invoked without a number, the trigger parsing is correct.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "feat(arp): v5.4.0 — add /arp benchmark subcommand (Flash vs Pro scoring)"
```

---

## Task 3: Update .gitignore and Step 2 cleanup

**Files:**
- Modify: `.gitignore` in repo root (add `.arp_benchmark_*.json` glob)
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md` Step 2.6 (add benchmark artifacts to prune command)

- [ ] **Step 1: Check existing .gitignore**

```bash
grep "arp" /home/firman/agent-review-pipeline/.gitignore
```

Expected: existing entries for `.arp_session_log*.json` and `.arp_parse_error_*.txt`.

- [ ] **Step 2: Add benchmark glob to .gitignore**

In `.gitignore`, after the existing `.arp_*` entries, add:

```
.arp_benchmark_*.json
```

- [ ] **Step 3: Update Step 2.6 cleanup in SKILL.md**

In `SKILL.md` Step 2.6, the existing prune command is:

> Prune `.arp_session_log.*.json` and `.arp_parse_error_*.txt` older than 7 days from the repo root

Change to:

> Prune `.arp_session_log.*.json`, `.arp_parse_error_*.txt`, and `.arp_benchmark_*.json` older than 7 days from the repo root

The bash prune snippet (if present verbatim) should become:

```bash
find . -maxdepth 1 \( \
  -name '.arp_session_log.*.json' \
  -o -name '.arp_parse_error_*.txt' \
  -o -name '.arp_benchmark_*.json' \
\) -mtime +7 -delete
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "chore(arp): gitignore + prune benchmark artifacts"
```

---

## Task 4: Update README and plugin.json

**Files:**
- Modify: `plugins/agent-review-pipeline/README.md`
- Modify: `plugins/agent-review-pipeline/.claude-plugin/plugin.json`

- [ ] **Step 1: Add benchmark section to README**

In `README.md`, after the `### Flags` section (currently ends around line 94), add:

```markdown
### Benchmark Mode

Compare Gemini Flash vs Pro findings quality on a specific PR:
```
/arp benchmark 251
```

Runs both models against the PR, scores findings by precision / depth / FP rate, and prints a side-by-side comparison table. Read-only — no auto-fix, no commit, no PR comment.

Before running with Pro, verify the model has headless capacity:
```
scripts/probe-gemini.sh gemini-3.1-pro-preview
```
```

- [ ] **Step 2: Update plugin.json version**

In `.claude-plugin/plugin.json`, change:

```json
"version": "5.3.2",
```

to:

```json
"version": "5.4.0",
```

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-review-pipeline/README.md plugins/agent-review-pipeline/.claude-plugin/plugin.json
git commit -m "docs(arp): v5.4.0 — benchmark usage docs + version bump"
```

---

## Task 5: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add v5.4.0 entry at top of CHANGELOG**

At the top of `CHANGELOG.md`, after the current header line, prepend:

```markdown
## v5.4.0 — 2026-04-16

**feat: /arp benchmark — Flash vs Pro scoring**

New `benchmark` subcommand compares Gemini Flash (`gemini-3-flash-preview`) against Pro (`gemini-3.1-pro-preview`) on a specific PR. Scores findings by three numeric metrics — precision (confidence ≥ 0.80 fraction), depth (body length + file:line + fix_code composite), and FP rate (confidence < 0.70 fraction) — and prints a side-by-side ASCII table with a verdict. Writes `.arp_benchmark_<epoch>.json` artifact (gitignored, pruned after 7 days). Read-only: no auto-fix, no commit, no PR comment. Secret redaction applied to artifact at write-time (fail-closed). Motivation: ARP v5.3.0 hard-pinned Flash after Pro quota exhaustion — no empirical data existed to judge whether Pro findings are worth the higher cost. Benchmark provides the data.

**Usage:** `/arp benchmark 251`

**Note:** Probe Pro headless capacity before first run: `scripts/probe-gemini.sh gemini-3.1-pro-preview`

---
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(arp): v5.4.0 changelog entry"
```

---

## Task 6: E2E smoke test

**Verify in camis_api_native repo (or any repo with PR #251 open).**

- [ ] **Step 1: Verify benchmark trigger parsing**

In a Claude Code session in the camis_api_native project:

```
/arp benchmark
```

Expected: Claude aborts with *"Benchmark requires an explicit PR number: /arp benchmark \<PR\>"* — confirms trigger parsing and PR-required check work.

- [ ] **Step 2: Run benchmark dry-run**

```
/arp benchmark --dry-run 251
```

Expected:
- Flash dispatch runs (see Gemini CLI invocation in shell)
- Pro dispatch runs (model probe first — may fail if Pro capacity exhausted)
- Table prints to stdout
- No `.arp_benchmark_*.json` file written (dry-run)

If Pro capacity exhausted: table shows `PARSE FAILED` for Pro row, `note` explains. This is expected behavior per the spec — note it and verify the fallback path works correctly.

- [ ] **Step 3: Run benchmark live**

```
/arp benchmark 251
```

Expected:
- Both dispatches complete (or Pro shows parse failed / capacity exhausted)
- Table prints with numeric scores
- `.arp_benchmark_<epoch>.json` written in repo root
- File is gitignored: `git status` shows no new tracked file

- [ ] **Step 4: Inspect artifact**

```bash
cat .arp_benchmark_*.json | jq '.flash.scores, .pro.scores, .verdict'
```

Expected: valid JSON with precision/depth/fp_rate/total_findings fields. No raw secrets (run `grep -E 'sk-|eyJ|AKIA|Bearer ' .arp_benchmark_*.json` — should match nothing).

- [ ] **Step 5: Cleanup**

```bash
rm .arp_benchmark_*.json
```

---

## Self-Review Notes

**Spec coverage check:**
- ✅ Architecture (Opsi B, standalone, Gemini-only benchmark) → Task 2
- ✅ Invocation `benchmark [PR]` → Task 2 Step 2 trigger section
- ✅ Flash dispatch → Task 2 Step 2 Flash Dispatch section
- ✅ Pro dispatch + probe note → Task 2 Step 2 Pro Dispatch section
- ✅ Three metrics (precision/depth/fp-rate) → Task 2 Step 2 Score section
- ✅ Token count field → Task 2 Step 2 Score section
- ✅ Verdict logic → Task 2 Step 2 Verdict section
- ✅ ASCII table output → Task 2 Step 2 Output section
- ✅ `.arp_benchmark_*.json` artifact schema → Task 2 Step 2 Artifact section
- ✅ `--dry-run` suppresses artifact write → Task 2 Step 2 Artifact + Safety sections
- ✅ Secret redaction → Task 2 Step 2 Artifact section
- ✅ Gitignore + prune → Task 3
- ✅ README update → Task 4
- ✅ Version bump → Task 4
- ✅ CHANGELOG → Task 5
- ✅ E2E test → Task 6

**No placeholders found.** All code blocks show exact content. All bash commands include expected output.

**Type consistency:** `precision`, `depth`, `fp_rate`, `total_findings`, `est_tokens` used consistently across Score section, Artifact schema, and Output table.
