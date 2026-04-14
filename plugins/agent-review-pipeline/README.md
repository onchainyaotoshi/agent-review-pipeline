# agent-review-pipeline

Multi-engine 5-stage autonomous code review pipeline for [Claude Code](https://claude.ai/code) with **Dual-Engine Consensus**. Submits your PR to [Codex](https://github.com/openai/codex-plugin-cc) and [Gemini CLI](https://github.com/google-gemini/gemini-cli) concurrently, dedups findings by confidence score, auto-fixes inline, and generates proving tests before commit.

## What It Does

1. **Cross-Engine Consensus** — Both Codex and Gemini review every file in parallel. Same file/line flagged by both engines gets a `+0.15` confidence boost. Findings below `0.60` confidence are dropped. Eliminates single-engine hallucinations.
2. **5-Stage Pipeline:**
   * **0. Context Setup** — Scans repo for `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `CONTRIBUTING.md`. Injects rules into both engines.
   * **1. Correctness Review** — Logic errors, null derefs, type mismatches, missing error handling.
   * **2. Impact Analysis** — Scans codebase for consumers/callers of changed code. Holistic loop: if fixes are applied, returns to Stage 1 for regression check.
   * **3. Adversarial Review** — Edge cases, races, security bypasses. Holistic loop back to Stage 1 if fixes applied.
   * **4. Test Generation** — Writes/updates unit tests proving each fix works.
   * **5. Deliver & PR Report** — `git commit` + `gh pr comment` with executive summary.
3. **Autonomous Auto-Fix Loop** — Applies `fix_code` directly via Edit tool, re-runs each stage until PASS or `maxIterations` reached.

## How It Differs from Manual Reviews & Single-Engine Agents

| Single-Engine Agent | ARP v4.1 (Consensus) |
|---------------------|----------------------|
| One LLM, blind trust | Two LLMs must agree (or score high) before acting |
| Suggests, leaves fix to human | Auto-fixes inline, re-runs until PASS |
| One stage, then stops | Chains correctness → impact → adversarial → test-gen automatically |
| No regression check | Holistic loop: Stage 2/3 fixes rewind to Stage 1 |
| Just edits files | Generates a unit test proving each fix works |
| Generic advice | Reads `CLAUDE.md` / `AGENTS.md`, applies your team's standards |

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) installed and authenticated + [Codex plugin](https://github.com/openai/codex-plugin-cc):
  ```
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
  ```
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) installed and authenticated — verify with `gemini --version`. ARP dispatches Gemini via the `compound-engineering:review:ce-review` subagent, so install [compound-engineering](https://github.com/anthropics/compound-engineering-plugin) too.

Install only the engines you need. Use `/arp codex` or `/arp gemini` to force a single engine if the other isn't ready.

## Installation

```
/plugin marketplace add onchainyaotoshi/agent-review-pipeline
/plugin install agent-review-pipeline@agent-review-pipeline
/reload-plugins
```

## Usage

Auto-detect target, dual-engine by default:
```
/arp
```

Review a specific PR:
```
/arp 42
```

Review specific files or directories:
```
/arp src/auth.js src/handlers/
```

### Engine Selection

ARP defaults to running **both** engines concurrently for consensus validation. Override:

```
/arp both                      # Codex + Gemini on every file (default)
/arp codex                     # Codex only
/arp gemini                    # Gemini only
/arp gemini src/components/    # Gemini only, scoped to dir
```

### Flags

| Flag | Alias | Description |
|------|-------|-------------|
| `--max-iterations N` | `-n N` | Max auto-fix iterations per stage (default: 3, `0` = unlimited) |

```
/arp -n 5 42          # up to 5 iterations per stage on PR 42
/arp -n 0 gemini      # unlimited iterations, Gemini only
```

Or just ask Claude:
> "Review PR 42" / "Check this before commit"

## Configuration (`plugin.json` userConfig)

| Key | Default | Description |
|-----|---------|-------------|
| `maxIterations` | `3` | Auto-fix retry limit per stage (`0` = unlimited) |
| `failOnError` | `false` | Abort on first stage that can't PASS instead of escalating |
| `defaultEngine` | `"both"` | Engine when none specified on CLI: `both`, `codex`, `gemini` |
| `geminiModel` | `"gemini-3.1-pro-preview"` | Model override for the Gemini subagent |
| `autoCommit` | `true` | Autonomously `git commit` fixes at Stage 5 |
| `postPrComment` | `true` | Auto-post executive summary via `gh pr comment` |

## Pipeline

```
   ┌────────────────────────────────────────┐
   │ 0. Context Setup                       │
   │    Scan CLAUDE.md / AGENTS.md / etc.   │
   │    Resolve PR target via gh pr diff.   │
   └──────────────────┬─────────────────────┘
                      │
   ┌──────────────────▼─────────────────────┐
   │ 1. Correctness  (Codex + Gemini parallel)│
   │    Merge + dedup → boost on consensus  │
   │    Auto-fix → re-run until PASS or max │
   └──────────────────┬─────────────────────┘
                      │ PASS
   ┌──────────────────▼─────────────────────┐
   │ 2. Impact Analysis                     │
   │    Auto-fix → if edited: DIRTY → →1    │
   └──────────────────┬─────────────────────┘
                      │ SAFE
   ┌──────────────────▼─────────────────────┐
   │ 3. Adversarial Review                  │
   │    Auto-fix → if edited: DIRTY → →1    │
   └──────────────────┬─────────────────────┘
                      │ PASS
   ┌──────────────────▼─────────────────────┐
   │ 4. Test Generation                     │
   │    Write/update unit tests for fixes   │
   └──────────────────┬─────────────────────┘
                      │
   ┌──────────────────▼─────────────────────┐
   │ 5. Deliver — git commit + gh pr comment│
   └────────────────────────────────────────┘
```

## Example Output

```
Agent Review Pipeline: PASS  (Dual-Engine Consensus)

Stage 1 — Correctness:
- Codex  (1/3 iter): 2 findings, confidence 0.78 / 0.82
- Gemini (1/3 iter): 1 finding, confidence 0.71
- Consensus: 1 same-line agreement → boosted to 0.93
- Fixes applied: 3

Stage 2 — Impact Analysis:
- 7 dependents checked → 1 breaking signature → fixed
- DIRTY → re-run Stage 1: PASS

Stage 3 — Adversarial:
- Codex: race in renderComplete → debounce added
- Gemini: PASS

Stage 4 — Test Generation:
- 3 unit tests added, all pass

Stage 5 — Deliver:
- chore(arp): autonomous review fixes
- PR comment posted
```

`N/max iter` — N = how many cycles ran, max = configured limit. `3/3 ESCALATED` means the engine hit the limit with remaining issues.

## License

MIT
