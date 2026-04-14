---
name: arp
description: Multi-engine 3-stage review pipeline (correctness + impact + adversarial). Auto-routes backend→Codex, frontend→Gemini, mixed→parallel both. Auto-fix loop. Run when user asks to review a PR, check code, or validate before commit.
argument-hint: "[-n N] [engine|backend:E frontend:E] [PR number | files]"
---

# Agent Review Pipeline (`/arp`)

Multi-engine 3-stage review pipeline with automatic engine routing and auto-fix loop. Files get classified by domain (backend / frontend / neutral) and dispatched to the engine best suited for that domain. Mixed-domain changes run engines in parallel.

## Architecture — 3 Independent Layers

Adding a new model = data edit in the tables below, not a logic rewrite.

### Layer 1: File → Domain (classifier)

First matching row wins. Unmatched files → `ambiguous`.

| Domain | Path patterns (glob) | Extensions |
|--------|----------------------|------------|
| `skip` | `**/node_modules/**`, `**/vendor/**`, `**/dist/**`, `**/build/**`, `**/.git/**`, `**/tmp/**` | `.png .jpg .jpeg .gif .pdf .lock` |
| `backend` | `**/api/**`, `**/server/**`, `**/backend/**`, `**/services/**`, `**/controllers/**`, `**/routes/**`, `**/models/**`, `**/migrations/**`, `**/db/**`, `**/jobs/**`, `**/workers/**`, `**/cron/**`, `**/scripts/**`, `**/tools/**` | `.py .go .rb .php .rs .sql .kt .scala .java .c .cpp .cs` |
| `frontend` | `**/components/**`, `**/pages/**`, `**/ui/**`, `**/frontend/**`, `**/client/**`, `**/web/**`, `**/app/**`, `**/public/**`, `**/static/**`, `**/assets/**`, `**/styles/**` | `.jsx .tsx .vue .svelte .scss .sass .less .astro` |
| `neutral` | `**/docs/**`, `**/views/**` (templates), `README*` | `.md .json .yaml .toml .ejs .hbs` |

Ambiguous `.js` / `.ts`: resolved by path. If inside a backend path → backend; inside a frontend path → frontend; otherwise → `ambiguous` (see Layer 2).

**Project-level override:** see `.arp.json` section below.

### Layer 2: Domain → Engine (policy)

| Domain | Default engine |
|--------|----------------|
| `backend` | `codex` |
| `frontend` | `gemini` |
| `neutral` | `codex` |
| `ambiguous` | `[codex, gemini]` (both, in parallel) |
| `skip` | *(not reviewed)* |

### Layer 3: Engine → Dispatch (invocation)

| Engine | Dispatch | Target / Command |
|--------|----------|------------------|
| `codex` | `subagent` | `codex:codex-rescue` (Agent tool) |
| `gemini` | `bash` | `gemini -p "$PROMPT" --approval-mode plan -o text` |

**Placeholders** in `bash` commands:
- `$PROMPT` — full stage prompt text with embedded file list (mandatory)
- `$MODEL` — expanded from `modelFlag` + configured model if set (optional, engine-specific)

**Dispatch types:**
- `subagent` — call via Agent tool with `subagent_type = target`
- `bash` — run via Bash tool, prompt substituted into command (use `printf '%s' "$PROMPT" | <cmd> -p -` if prompt > 100KB)
- `mcp` — call MCP tool `target` with `{ prompt }` arg (reserved for future engines)

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `maxIterations` | `3` | Max auto-fix iterations per stage per engine (`0` = unlimited) |
| `failOnError` | `false` | Abort on first stage that can't PASS (instead of escalating) |
| `defaultEngine` | `auto` | `auto` (route by domain) / `codex` / `gemini` / `both` |
| `geminiModel` | `""` | Optional `-m <model>` for gemini CLI (e.g. `gemini-2.5-pro`) |

Set globally: `/plugin config agent-review-pipeline`. Override per-run via CLI flags.

### CLI flags and arguments

| Flag / token | Alias | Description |
|--------------|-------|-------------|
| `--max-iterations N` | `-n N` | Override `maxIterations` (`0` = unlimited) |
| `<engine>` | — | Force single engine on all files. Any key from the Layer 3 registry, or `both`. |
| `<domain>:<engine>` | — | Per-domain override, e.g. `backend:codex frontend:gemini neutral:codex`. Multiple allowed. |
| *(anything else)* | — | Review target (PR number, branch, file path, dir) |

Reserved engine tokens: any key in Layer 3 (`codex`, `gemini`, future additions) plus `both` and `auto`. Anything else is treated as a review target.

### Examples

```
/arp                                      # auto-route, auto-detect target
/arp 42                                   # auto-route on PR 42
/arp codex                                # force codex on all files, auto-detect target
/arp gemini src/components/               # force gemini on dir
/arp both                                 # run codex + gemini on every file
/arp backend:codex frontend:gemini        # explicit per-domain (same as default)
/arp -n 5 gemini                          # max 5 iter, force gemini
/arp -n 0 42                              # unlimited auto-route on PR 42
```

## Prerequisites

- **Codex plugin** for Claude Code — provides the `codex:codex-rescue` subagent
- **Gemini CLI** installed and authenticated — verify with `gemini --version`
- Optional: project `.arp.json` for repo-specific routing (see below)

## When to Use

- Only when the user asks — "review PR 42", "run /arp", "check before commit"
- Before committing if the user asks to commit
- **Do not** run automatically after every coding session

## Pipeline

```
┌─────────────────────────────────────┐
│ 0. Classify files → group by domain │
│    Resolve engine per group         │
└────────────┬────────────────────────┘
             │
┌────────────▼────────────────────────┐
│ 1. Correctness (per engine, parallel across domains) │
│    auto-fix loop                    │
└────────────┬────────────────────────┘
             │ all groups PASS ↓
┌────────────▼────────────────────────┐
│ 2. Impact Analysis (per engine)     │
│    auto-fix loop                    │
└────────────┬────────────────────────┘
             │ all groups SAFE ↓
┌────────────▼────────────────────────┐
│ 3. Adversarial (per engine)         │
│    auto-fix loop                    │
└────────────┬────────────────────────┘
             │ all groups PASS ↓
┌────────────▼────────────────────────┐
│ 4. Deliver                          │
└─────────────────────────────────────┘
```

## How to Run

### Step 0: Parse args, classify, route

1. Strip flags (`-n N` / `--max-iterations N`) and apply to `maxIterations`.
2. Scan remaining tokens left-to-right:
   - If token matches an engine key (Layer 3) or `both` / `auto` → record as engine override (applies to all files unless `<domain>:<engine>` form is used).
   - If token matches `<domain>:<engine>` where `<domain> ∈ {backend, frontend, neutral, ambiguous}` → record as per-domain override.
   - Otherwise → append to review targets.
3. Resolve targets:
   - Numeric → `gh pr diff <n> --name-only`
   - Looks like a branch → `git diff main...<branch> --name-only`
   - Looks like a file/dir path → use as-is
   - Empty → `gh pr list --state open --json number,title,headRefName`. 0 open → `git diff --name-only main...HEAD`. 1 open → auto-use. 2+ → ask user.
4. If `.arp.json` exists at repo root, load and merge over Layer 1/2/3 defaults (per-project customization).
5. Classify every target file via Layer 1. Drop `skip` files.
6. Resolve engine per file via Layer 2 (with CLI and `.arp.json` overrides applied).
7. Group files by (domain, engine). Each group reviews independently.

### Step 1: Correctness Review

For each (domain, engine, files) group **in parallel** (dispatch all groups at once, await all):

**Subagent dispatch:**
```
Agent(subagent_type=engine.target, prompt=<correctness prompt>)
```

**Bash dispatch:**
```
PROMPT="<correctness prompt with file paths embedded>"
cmd = engine.command with $PROMPT substituted (via env var or argv)
Bash(cmd)
```
For Gemini specifically: pass prompt via `-p "$PROMPT"`; if `geminiModel` is set, append `-m "$geminiModel"`; run in repo root so Gemini picks up workspace context.

**Correctness prompt:**
```
Review these files: [file1, file2, ...]

Check for: logic errors, null dereferences, missing functions,
column/data mismatches, type mismatches, missing error handling.

Report PASS if no issues, or list each issue as:
- severity (Critical/High/Medium/Low), file:line, description, recommended fix.
```

**If any group reports findings:**
1. Read each finding (severity, file, line, recommendation).
2. Apply fixes via the Edit tool (always to main Claude's working copy — not inside the subagent).
3. Re-run that group's engine with the same prompt + file list.
4. Loop until PASS or `maxIterations` hit.

Other groups that already PASS are not re-run when another group is still iterating.

**When all groups PASS:** advance to Step 2.

### Step 2: Impact Analysis

Same parallel dispatch per group. Prompt:
```
Impact analysis for changes in: [files]

1. IDENTIFY: what functions/classes/exports/APIs changed? Old vs new signature.
2. FIND DEPENDENTS: search the entire codebase for all files that import or use
   the changed symbols (use grep/glob — be thorough).
3. ASSESS each dependent:
   - Is the change backward-compatible?
   - Could it break the dependent's behavior?
   - Watch for: callers that rely on old return types, shared components,
     any consumer that extends or composes the changed symbols.
4. Report SAFE if no breaking changes, or list each affected file with:
   - what it uses from the changed file
   - why it might break
   - severity (Critical/High/Medium/Low).
```

**If breaking impacts found:** fix to restore backward compatibility OR update all affected dependents, then re-run. Loop until SAFE or `maxIterations` hit.

**When all groups SAFE:** advance to Step 3.

### Step 3: Adversarial Review

Same parallel dispatch. Prompt:
```
ADVERSARIAL review: [files]. Try to BREAK this code. Think like a hostile tester.

Construct failure scenarios: edge cases, data loss, double-counting, stale state,
race conditions, validation bypass, integer overflow, empty/null inputs,
concurrent event handlers firing twice.

Focus on ACTUAL BUGS that crash the program or produce wrong data.

Report each finding with severity (Critical/High/Medium/Low) and file:line.
```

**If findings:** read, fix via Edit, re-run. Loop until PASS or `maxIterations` hit.

### Step 4: Deliver

Summarize all stages with routing breakdown and per-engine iteration counts:

```
Agent Review Pipeline: PASS

Routing:
- backend (3 files) → codex
- frontend (5 files) → gemini
- neutral (1 file) → codex

Correctness:
- codex (1/3 iter): PASS on first run
- gemini (2/3 iter): Fix 1 — null guard on updateRow before cell.getElement()

Impact Analysis:
- codex (1/3 iter): 7 dependents checked, SAFE
- gemini (1/3 iter): no UI dependents, SAFE

Adversarial:
- codex (1/3 iter): PASS
- gemini (2/3 iter): Fix 1 — concurrent renderComplete double-fire → debounce added

All fixes applied. Ready to test.
```

`N/max iter` format: N = review cycles actually executed, max = configured `maxIterations`. `3/3 ESCALATED` = hit the limit; remaining issues listed for user.

## Project-Level Override: `.arp.json`

Place `.arp.json` in the repo root to customize routing for a specific project without forking the plugin. All keys optional — anything not specified falls back to the defaults in this skill.

```json
{
  "domains": {
    "backend": {
      "paths": ["modules/node_modules/**", "services/**", "scripts/**"],
      "extensions": [".py", ".go", ".js"]
    },
    "frontend": {
      "paths": ["modules/*/index.*", "modules/*/*/index.*", "public/**"],
      "extensions": [".html", ".css", ".js"]
    }
  },
  "domainEngine": {
    "backend": "codex",
    "frontend": "gemini",
    "neutral": "codex",
    "ambiguous": ["codex", "gemini"]
  },
  "engines": {
    "qwen": {
      "dispatch": "bash",
      "command": "qwen-cli chat -p \"$PROMPT\"",
      "model": "qwen-coder"
    }
  }
}
```

Merge rules:
- Array values **replace** defaults (copy defaults into `.arp.json` if you want to extend rather than replace).
- Objects merge key-by-key.
- `engines` entries **add to** the registry (so `.arp.json` can introduce new engines without replacing built-ins).

Real-world example — `camis_api_native` has `modules/node_modules/` containing first-party Express code (not vendored deps). Its `.arp.json` would force those paths into `backend`, while `modules/*/index.js` (browser consumer scripts) maps to `frontend`.

## Adding a New Engine

Tell the assistant the engine's shape; it edits the tables above.

### Minimum info

1. **Name** — short key (`claude`, `grok`, `qwen`, ...)
2. **Dispatch** — `subagent` | `bash` | `mcp`
3. **Target / command** — subagent type, shell command with `$PROMPT` placeholder, or MCP tool name
4. **Domain(s)** it should handle — `backend`, `frontend`, `neutral`, or `any`
5. *(optional)* Model flag, env vars, replace vs coexist with an existing engine

### Example requests

> "add `claude` engine, subagent `general-purpose`, handle neutral"

> "add `grok` engine, bash `grok -p \"$PROMPT\" --review`, handle backend, replace codex"

> "add `qwen` engine, bash `qwen-cli chat -p \"$PROMPT\"`, model flag `-m qwen-coder`, handle frontend alongside gemini"

### Steps the assistant performs

1. Append a row to the Layer 3 engine registry (above).
2. Update Layer 2 domain → engine mapping if routing changed.
3. Add any new config key (e.g. `grokModel`) to `plugin.json` `userConfig`.
4. Update the README engine list.
5. Bump plugin version — minor for additive, major if replacing an existing engine.
6. Dry-run the dispatch once against a single file to confirm the command works end-to-end.

Users who want an engine only for one repo should define it in `.arp.json` instead of modifying the plugin source.

## Rules

1. **Use `codex:codex-rescue` via the Agent tool** (not the Skill tool). `codex:review` and `codex:adversarial-review` skills have `disable-model-invocation` and cannot be invoked programmatically.
2. **Use Gemini CLI headless** — always pass `--approval-mode plan` (read-only) for review stages. Never `--yolo` during review.
3. **Parallel dispatch across groups** — within a stage, every (domain, engine) group runs concurrently. Only after all groups PASS does the stage advance.
4. **Auto-fix inline** — the main Claude (orchestrator) applies fixes via Edit, then re-runs the affected group only.
5. **Never skip stages** — Correctness PASS does not imply safe. Run impact + adversarial too.
6. **Never skip impact analysis** — a file can be internally correct yet break every caller.
7. **Max iterations per engine per stage** — default 3, override via config or `-n`. `0` = unlimited. Hit limit → if `failOnError`, abort; else escalate remaining issues to the user.
8. **Scope per stage** — correctness and adversarial: only the changed files in that domain group. Impact: changed files + their dependents discovered via search.
9. **Skip binary / vendored files** — never dispatch files classified as `skip`.
10. **Deliver summary** — routing breakdown, per-engine iteration counts, all fixes applied.
