---
name: arp
description: Multi-engine 5-stage autonomous review pipeline. Default runs Codex + Gemini concurrently (Dual-Engine Consensus), dedups findings by confidence, auto-fixes inline, and generates proving tests.
argument-hint: "[-n N] [codex|gemini|both] [PR number | files]"
---

# Agent Review Pipeline (`/arp`)

Multi-engine 5-stage review pipeline with automatic dual-engine consensus, context-injection, and autonomous auto-fix loop.

## Architecture — Engine Registry

To bypass OS Argument Length limits, prompts are written to a temporary file `.arp_stage_prompt.md`.

| Engine | Dispatch | Target / Command |
|--------|----------|------------------|
| `codex` | `subagent` | `codex:codex-rescue` (Agent tool, prompt via file if supported) |
| `gemini` | `subagent` | `compound-engineering:review:ce-review` (Agent tool, pass `mode:headless`, files, and `geminiModel`) |

## Pipeline Flow (with Cross-Engine Consensus)

```
   ┌────────────────────────────────────────┐
   │ 0. Context Setup (Entire PR)           │
   └──────────────────┬─────────────────────┘
                      │
   ┌──────────────────▼─────────────────────┐
   │ 1, 2, 3. Review & Analysis             │
   │    (Concurrent: Gemini + Codex)        │
   └──────────────────┬─────────────────────┘
                      │ Findings (JSON)
   ┌──────────────────▼─────────────────────┐
   │ 🧠 Merge & Confidence Scoring          │
   │ Orchestrator dedups findings. If both  │
   │ engines find the same bug, confidence  │
   │ score is boosted. Low scores dropped.  │
   └──────────────────┬─────────────────────┘
                      │ Validated Bugs
   ┌──────────────────▼─────────────────────┐
   │ 🛠️ Autonomous Auto-Fix Loop            │
   │ Apply fixes directly to code.          │
   │ Re-run checks until PASS or max N.     │
   └──────────────────┬─────────────────────┘
                      │ All Stages PASS
   ┌──────────────────▼─────────────────────┐
   │ 4. Test Generation (Prove fixes work)  │
   └──────────────────┬─────────────────────┘
                      │
   ┌──────────────────▼─────────────────────┐
   │ 5. Deliver & PR Report                 │
   └────────────────────────────────────────┘
```

## How to Run

### Step 0: Context & Route
1. Scan repo root for `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, or `CONTRIBUTING.md`. Store their contents to inject into the `<repository_rules>` block.
2. Resolve PR targets (via `gh pr diff <n>`).

### Step 1: Correctness Review
1. Write prompt and file contents to `.arp_stage_prompt.md`.
   - Prompt MUST instruct the engine to output findings in a strict JSON array format: `[{"file": "...", "line": 12, "severity": "high", "confidence": 0.85, "issue": "...", "fix_code": "..."}]`.
2. Dispatch **BOTH** engines (Gemini and Codex) concurrently.
3. **Merge & Deduplicate:** Orchestrator collects JSON. If both engines flag the same file/line, boost confidence by +0.15. Findings below 0.60 confidence are dropped.
4. **Auto-Fix:** Orchestrator applies the `fix_code` directly using the Edit tool.
5. **Loop:** Re-run Step 1 until PASS or `maxIterations` reached.

### Step 2: Impact Analysis
1. Write prompt to scan codebase for consumers/callers. Output JSON with `fix_code`.
2. Dispatch engines.
3. Apply fixes.
4. **Holistic Loop:** If edited, mark `DIRTY` and return to Step 1 for regression check.

### Step 3: Adversarial Review
1. Find edge cases/vulnerabilities. Output JSON with `fix_code`.
2. Dispatch engines.
3. Apply fixes.
4. **Holistic Loop:** If edited, mark `DIRTY` and return to Step 1.

### Step 4: Test Generation
1. Identify all files edited. Find corresponding unit tests.
2. Prompt: "Please write or update the unit test to prove the bug is resolved."
3. Ensure the test passes.

### Step 5: Deliver & PR Report
1. Orchestrator compiles summary of all iterations, auto-fixes, and tests added.
2. Execute `git add .` and `git commit -m "chore(arp): autonomous review fixes"`.
3. Post executive summary to GitHub PR via `gh pr comment`.
4. Clean up temporary files.
