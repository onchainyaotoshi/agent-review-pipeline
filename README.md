# agent-review-pipeline

Multi-engine 3-stage code review pipeline for [Claude Code](https://claude.ai/code). Auto-routes backend files to [Codex](https://github.com/openai/codex-plugin-cc), frontend files to [Gemini CLI](https://github.com/google-gemini/gemini-cli), mixed changes to both in parallel. Auto-fix loop until PASS.

> Previously `codex-review-pipeline` (Codex-only, v1.x). v2.0 adds Gemini, auto-routing, and a pluggable engine registry.

## What It Does

Chains three review stages into a single pipeline with **automatic fix-and-retry**:

1. **Correctness Review** — logic errors, null derefs, missing functions, type mismatches
2. **Impact Analysis** — does this break any caller or dependent menu/component?
3. **Adversarial Review** — actively tries to *break* your code: edge cases, data loss, race conditions, validation bypass
4. **Deliver** — routing breakdown, per-engine iteration counts, every fix applied

Before stage 1, every changed file is classified by domain and routed to the engine best suited for it:

- Backend file → Codex
- Frontend file → Gemini
- Ambiguous `.js` / `.ts` outside a backend or frontend path → both engines in parallel
- Binary / vendored / build output → skipped

Each engine auto-fixes and re-runs until PASS (default 3 iterations). Hitting the limit escalates remaining issues to the user.

```
┌─────────────────────────────────────┐
│ 0. Classify + group by (domain,     │
│    engine). Apply overrides.        │
└──────────────────┬──────────────────┘
┌──────────────────▼──────────────────┐
│ 1. Correctness   (groups parallel)  │
│    each auto-fix → retry (max N)    │
└──────────────────┬──────────────────┘
                   │ all groups PASS
┌──────────────────▼──────────────────┐
│ 2. Impact analysis                  │
│    each auto-fix → retry (max N)    │
└──────────────────┬──────────────────┘
                   │ all groups SAFE
┌──────────────────▼──────────────────┐
│ 3. Adversarial                      │
│    each auto-fix → retry (max N)    │
└──────────────────┬──────────────────┘
                   │ all groups PASS
┌──────────────────▼──────────────────┐
│ 4. Deliver                          │
└─────────────────────────────────────┘
```

## How It Differs from Running Reviews Manually

| Standalone review | This pipeline |
|--------------------|---------------|
| Pick an engine by hand | Auto-routes per domain (or force with `/arp codex` etc.) |
| One engine covers everything | Right tool per domain — Codex for backend, Gemini for frontend |
| Stops after findings — fix manually | Auto-fixes inline and re-runs until PASS |
| No PR integration | PR number, branch, file paths, or auto-detect |
| Single stage per run | Chains correctness → impact → adversarial |

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) + [Codex plugin](https://github.com/openai/codex-plugin-cc) for Claude Code:
  ```
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
  ```
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) installed and authenticated — verify with `gemini --version`

Install whichever engines you want. Only one installed? Use `/arp codex` or `/arp gemini` to force that engine until the other is ready.

## Installation

```
/plugin marketplace add onchainyaotoshi/codex-review-pipeline
/plugin install agent-review-pipeline@codex-review-pipeline
/reload-plugins
```

## Usage

Auto-detect target and route engine per file:
```
/arp
```

Review a PR:
```
/arp 42
```

Review specific files / dirs:
```
/arp src/auth.js src/handlers/
```

### Engine override

Reserved tokens: `codex`, `gemini`, `both`, plus any engine you add via `.arp.json`.

```
/arp codex                              # force codex on all files
/arp gemini src/components/             # force gemini on a dir
/arp both                               # run codex + gemini on every file
/arp backend:codex frontend:gemini      # explicit per-domain (= default)
```

### Flags

| Flag | Alias | Description |
|------|-------|-------------|
| `--max-iterations N` | `-n N` | Max auto-fix iterations per stage per engine (default 3, `0` = unlimited) |

Yolo mode — unlimited iterations until PASS:
```
/arp -n 0 42
```

Custom cap:
```
/arp -n 5 gemini src/components/
```

Or just ask Claude:
> "Review PR 42" / "Check this before commit"

## Engines (default registry)

| Engine | Dispatch | Handles |
|--------|----------|---------|
| `codex` | `codex:codex-rescue` subagent | `backend`, `neutral` |
| `gemini` | `gemini -p "$PROMPT" --approval-mode plan -o text` | `frontend` |

Ambiguous files (e.g. `.js` outside a recognized path) run through **both** engines in parallel.

### Adding another engine

Ask Claude with this shape:
> "add `qwen` engine, bash `qwen-cli chat -p \"$PROMPT\"`, handle frontend alongside gemini"

Full template: `plugins/agent-review-pipeline/skills/arp/SKILL.md` → *Adding a New Engine*.

### Per-project customization (`.arp.json`)

Drop `.arp.json` in your repo root to override routing for that project only — no fork needed:

```json
{
  "domains": {
    "backend":  { "paths": ["modules/node_modules/**", "services/**"] },
    "frontend": { "paths": ["modules/*/index.*", "public/**"] }
  },
  "domainEngine": {
    "backend": "codex",
    "frontend": "gemini"
  }
}
```

Use this when your project layout doesn't match the generic defaults (e.g. `modules/node_modules/` holds first-party Express code instead of vendored deps).

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

`N/max iter` — N is how many cycles actually ran, max is the configured limit. `3/3 ESCALATED` = hit the limit with remaining issues handed back to the user.

## License

MIT
