# ARP Benchmark Tool — Design Spec

**Date:** 2026-04-16
**Scope:** Standalone benchmark subcommand for ARP — compare Gemini Flash vs Pro findings quality + cost

---

## Problem

ARP v5.3.0 hard-pinned Gemini to `gemini-3-flash-preview` after Pro exhausted quota on release day. No data exists to judge whether Pro findings are worth the higher cost. Before deciding to re-enable Pro or keep Flash, need empirical comparison.

---

## Approach

Opsi B: Build benchmark tool first (standalone), harness later. Benchmark runs both models live against a real PR, scores findings numerically, outputs comparison report. Benchmark artifacts (`.arp_benchmark_*.json`) designed to be reusable as test harness fixtures later.

---

## Architecture

```
/arp benchmark [PR]
        │
        ├── Dispatch Gemini Flash   ──► parse findings → score set F
        └── Dispatch Gemini Pro     ──► parse findings → score set P
                                                │
                                      compare(F, P) → numeric report
```

- Implemented as new section in `SKILL.md` (not a separate file)
- Isolated from main review flow — no auto-fix, no PR comment, no commit
- Baseline PR: `camis_api_native#251` — must be passed explicitly (`/arp benchmark 251`); no auto-detect default
- Models: Flash = `gemini-3-flash-preview`, Pro = `gemini-3.1-pro-preview` (empirical probe required before pinning — UI label is `gemini-3.1-pro` but headless `-m` flag may differ)

---

## Scoring Metrics

Three metrics, each scored 0–1 per finding:

| Metric | Definition |
|--------|------------|
| **Precision** | Proxy: confidence score from fingerprint merge step. Findings with confidence ≥ 0.80 counted as high-precision. Aggregate = fraction of findings meeting threshold. |
| **Depth** | Composite: finding body length (non-trivial = >100 chars) + presence of `file:line` reference + presence of `fix_code`. Score = (components met) / 3. |
| **FP Rate** | Suspected false positive: confidence < 0.70 (no Codex dispatch in benchmark mode — confidence-only proxy). Rate = fraction of findings flagged. Lower is better. |

Token usage reported if available from Gemini response metadata.

---

## Output

Terminal report after benchmark completes:

```
╔══════════════════════════════════════════════════╗
║  ARP Benchmark — PR #251 (camis_api_native)      ║
╠══════════════════════╦═══════════╦═══════════════╣
║ Metric               ║ Flash     ║ Pro           ║
╠══════════════════════╬═══════════╬═══════════════╣
║ Total findings       ║ —         ║ —             ║
║ Precision (≥0.80)    ║ —         ║ —             ║
║ Depth score          ║ —         ║ —             ║
║ Suspected FP rate    ║ —         ║ —             ║
║ Est. tokens used     ║ —         ║ —             ║
╠══════════════════════╬═══════════╬═══════════════╣
║ Verdict              ║ ?         ║ ?             ║
╚══════════════════════╩═══════════╩═══════════════╝
```

Verdict logic:
- If Pro precision > Flash precision by >0.10 AND Pro FP rate < Flash FP rate → `Pro: MORE ACCURATE`
- If Flash/Pro within 0.10 precision → `Flash: GOOD ENOUGH (cheaper)`
- Otherwise → `INCONCLUSIVE — review session log`

Also writes `.arp_benchmark_<timestamp>.json` — same schema as existing session log, forward-compatible with future harness.

---

## Invocation

```bash
/arp benchmark 251     # run benchmark on PR #251
/arp benchmark 251     # explicit PR number
/arp benchmark --dry-run 251  # run dispatches + score, skip writing .arp_benchmark_*.json artifact
```

---

## Safety Constraints

- No auto-fix, no PR comment, no commit during benchmark
- Both dispatches run `mode:report-only`
- `snapshot_git` pre/post each dispatch (same read-only enforcement as main flow)
- Secret redaction applied to `.arp_benchmark_*.json` on write
- Benchmark runs Gemini only (no Codex dispatch — FP rate uses confidence-only proxy)

---

## Out of Scope

- Integration test harness (separate future work)
- Codex Flash vs Pro comparison (Codex has no equivalent model split)
- Automatic model selection based on benchmark result (manual decision by user)
- CI/CD automation of benchmark

---

## Future Hook

`.arp_benchmark_*.json` artifacts are designed as fixture candidates. When integration test harness is built, these can be replayed without live LLM calls.
