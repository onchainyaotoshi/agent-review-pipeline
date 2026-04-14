# agent-review-pipeline

Multi-engine 3-stage code review pipeline for [Claude Code](https://claude.ai/code). Auto-routes backend files to [Codex](https://github.com/openai/codex-plugin-cc), frontend files to [Gemini CLI](https://github.com/google-gemini/gemini-cli), mixed changes to both in parallel. Auto-fix loop until PASS.

## What It Does

1. **Classify** every changed file as `backend`, `frontend`, `neutral`, or `skip`
2. **Route** each group to the engine best suited for that domain (configurable)
3. Run three review stages per group, in parallel across engines:
   - **Correctness** — logic errors, null derefs, type mismatches, missing error handling
   - **Impact analysis** — does this break any caller or dependent menu?
   - **Adversarial** — actively tries to break the code: edge cases, data loss, races, bypass
4. Auto-fix issues inline, re-run until PASS (max 3 iterations per engine per stage by default)
5. **Deliver** a routing breakdown + per-engine iteration counts + every fix applied

## How It Differs from Manual Reviews

| Standalone review | This pipeline |
|-------------------|---------------|
| Pick an engine manually | Auto-routes per domain (or user override) |
| One engine covers everything | Right tool for each domain (Codex for backend, Gemini for frontend) |
| Stops after finding issues — fix by hand | Auto-fixes and re-runs until PASS |
| One stage only | Chains correctness → impact → adversarial automatically |
| No PR integration | Accepts PR number, branch, file paths, or auto-detects |

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) installed and authenticated + [Codex plugin](https://github.com/openai/codex-plugin-cc):
  ```
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
  ```
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) installed and authenticated — verify with `gemini --version`

Only install the engines you need. Install one and use `/arp codex` or `/arp gemini` to force that single engine until the other is ready.

## Installation

```
/plugin marketplace add onchainyaotoshi/agent-review-pipeline
/plugin install agent-review-pipeline@agent-review-pipeline
/reload-plugins
```

## Usage

Auto-detect target and engine:
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

### Engine override

Reserved tokens: `codex`, `gemini`, `both`, or any engine added via `.arp.json`.

```
/arp codex                              # force codex on all files
/arp gemini src/components/             # force gemini on dir
/arp both                               # run codex + gemini on every file
/arp backend:codex frontend:gemini      # explicit per-domain assignment
```

### Flags

| Flag | Alias | Description |
|------|-------|-------------|
| `--max-iterations N` | `-n N` | Max auto-fix iterations per stage per engine (default: 3, `0` = unlimited) |

```
/arp -n 5 42          # up to 5 iterations per stage on PR 42
/arp -n 0 gemini      # unlimited iterations, force gemini
```

Or just ask Claude:
> "Review PR 42" / "Check this before commit"

## Engines

| Engine | Dispatch | Handles by default |
|--------|----------|--------------------|
| `codex` | `codex:codex-rescue` subagent | `backend`, `neutral` |
| `gemini` | `gemini -p "$PROMPT" --approval-mode plan -o text` | `frontend` |

Ambiguous `.js` / `.ts` files outside a backend or frontend path route to **both** engines in parallel.

### Adding another engine

Tell the assistant the engine's shape and it edits the registry:
> "add `qwen` engine, bash `qwen-cli chat -p \"$PROMPT\"`, handle frontend alongside gemini"

See `plugins/agent-review-pipeline/skills/arp/SKILL.md` → *Adding a New Engine* for the full template.

## Project-Level Override

Drop `.arp.json` in your repo root to customize routing without forking the plugin. Useful when your project's layout doesn't match the generic defaults.

```json
{
  "domains": {
    "backend": { "paths": ["modules/node_modules/**", "services/**"] },
    "frontend": { "paths": ["modules/*/index.*", "public/**"] }
  },
  "domainEngine": {
    "backend": "codex",
    "frontend": "gemini"
  }
}
```

Full schema: see the skill doc.

## Pipeline

```
   ┌────────────────────────────────────────┐
   │ 0. Classify files → group by (domain,  │
   │    engine). Apply CLI / .arp.json /    │
   │    config overrides.                   │
   └──────────────────┬─────────────────────┘
                      │
   ┌──────────────────▼─────────────────────┐
   │ 1. Correctness   (all groups parallel) │
   │    each group auto-fix → re-run (max N)│
   └──────────────────┬─────────────────────┘
                      │ all groups PASS
   ┌──────────────────▼─────────────────────┐
   │ 2. Impact analysis (all groups         │
   │    parallel, auto-fix → re-run max N)  │
   └──────────────────┬─────────────────────┘
                      │ all groups SAFE
   ┌──────────────────▼─────────────────────┐
   │ 3. Adversarial   (all groups parallel, │
   │    auto-fix → re-run max N)            │
   └──────────────────┬─────────────────────┘
                      │ all groups PASS
   ┌──────────────────▼─────────────────────┐
   │ 4. Deliver  — routing + iteration      │
   │    counts + fixes applied              │
   └────────────────────────────────────────┘
```

## Example Output

```
Agent Review Pipeline: PASS

Routing:
- backend  (3 files) → codex
- frontend (5 files) → gemini
- neutral  (1 file)  → codex

Correctness:
- codex  (1/3 iter): PASS on first run
- gemini (2/3 iter): Fix 1 — null guard on updateRow before cell.getElement()

Impact Analysis:
- codex  (1/3 iter): 7 dependents checked, SAFE
- gemini (1/3 iter): no UI dependents, SAFE

Adversarial:
- codex  (1/3 iter): PASS
- gemini (2/3 iter): Fix 1 — concurrent renderComplete double-fire → debounce added

All fixes applied. Ready to test.
```

`N/max iter` — N is how many review cycles ran, max is the configured limit. `3/3 ESCALATED` means the engine hit the limit with remaining issues.

## License

MIT
