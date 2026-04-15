# Integration Test Harness — Spec (Draft)

> Status: DRAFT. Named production blocker in CONTRIBUTING.md + CHANGELOG. This spec proposes the first concrete approach. Not implemented yet.

## Motivation

ARP is a prompt-driven skill. Every "test" to date has been a live end-to-end run against a real PR with real Codex + Gemini quota burn. The 2026-04-15 rc1→rc3 cycle surfaced why that's insufficient:

- **Quota-blocked iteration.** The PR #1 run exhausted `gemini-3.1-pro-preview` for ~2 h. Any follow-up regression check has to wait for quota reset. Three rc cycles in one day cost most of an afternoon to real-world wait time.
- **Nondeterministic signal.** Codex and Gemini responses vary run-to-run. A test that passed last Tuesday tells you nothing about the pipeline today.
- **No failure-mode coverage.** The 41-min flash hang was discovered by *accident*. The WRITE-CHECK false-positive risk was discovered by *probe*. Neither is covered by any automated check.

A deterministic harness that replays canned dispatch outputs through the real merge/fingerprint/kill-switch/report-only code paths would turn rc-validation from "burn the afternoon on quota" into "run a bash script in 30 seconds."

## Goals

1. **Deterministic replay** of Codex + Gemini dispatch outputs. Given fixture inputs, the harness always produces the same session log and exit code.
2. **Failure-mode coverage** for every rc-surfaced blocker: WRITE-CHECK trigger, fingerprint collision, kill-switch, parse error, quota abort, ref-injection, flock contention.
3. **Stay prompt-native.** No Node/Go/Rust runtime. Harness is bash + jq + git; same tool surface the skill itself uses. Aligns with CONTRIBUTING's "Prompt-driven, not runtime-driven" principle.
4. **CI-friendly.** Runs in <30 s, no network, no LLM calls, no quota, no secrets. Pure fixture replay.

## Non-Goals

- Not a unit test for SKILL.md prose. Natural-language steps are interpreted by Claude; testing them requires an LLM in the loop, which breaks determinism. Cover *executable surfaces* only.
- Not a Codex/Gemini correctness test. Their findings quality is their problem.
- Not a replacement for a real e2e run. A successful harness run + one live run per rc remains the gate for tag-promotion.

## Fixture Model

Directory layout proposed under `tests/fixtures/`:

```
tests/
  fixtures/
    01-happy-path/
      pr.diff                      # what the PR looked like
      codex-correctness.json       # canned output for Dispatch 1
      codex-adversarial.json       # canned output for Dispatch 2
      gemini-ce-review.json        # canned output for Dispatch 3
      expected-session-log.json    # what merge should produce
      expected-exit-code           # single integer
    02-write-check-tripped/
      pr.diff
      codex-correctness.json
      codex-adversarial.json
      gemini-writes-a-file.sh      # side-effect simulator instead of JSON
      expected-exit-code           # 2
    03-fingerprint-collision/
      ...
    04-kill-switch/
      # same finding surfaces two iterations in a row
      ...
    05-parse-error/
      codex-correctness.json       # valid
      codex-adversarial.malformed  # broken JSON on purpose
      gemini-ce-review.json        # valid
      expected-parse_errors        # non-empty
    06-ref-injection/
      ref='; rm -rf /'
      expected-exit-code           # 1 (pre-dispatch reject)
    07-quota-abort/
      gemini-ce-review.429         # simulated 429 on primary + fallback
      ALLOW_FLASH_FALLBACK         # empty
      expected-exit-code           # 2 (or documented "degraded")
    08-flock-contention/
      ...
```

**Cassette format.** JSON dispatch outputs are captured from a real successful run once, then checked in. Fixtures are versioned and reviewed like code.

**PR.diff format.** A minimal unified diff that `git apply --check` validates. Harness creates a disposable worktree, applies the diff, runs the pipeline against it.

## Runner Design

`tests/run.sh`:

```bash
#!/usr/bin/env bash
# One script, one command: `bash tests/run.sh` runs every fixture.
# Exits non-zero on the first mismatch.

for fixture in tests/fixtures/*/; do
  name=$(basename "$fixture")
  echo "== $name =="

  # 1. Set up a scratch worktree with the fixture PR applied
  scratch=$(mktemp -d)
  git worktree add -q "$scratch"
  (cd "$scratch" && git apply "$fixture/pr.diff")

  # 2. Stage the canned dispatch outputs so the skill reads them instead of
  #    calling Codex/Gemini. The interception point is the dispatch wrapper
  #    (Bash tool invocation) — harness overrides $PATH to inject a fake
  #    `gemini` that cats the fixture file, and a fake `codex:codex-rescue`
  #    shim that returns the fixture JSON.
  export PATH="$fixture/fakes:$PATH"

  # 3. Run the skill in dry-run mode (no commit, no PR comment)
  actual_log="$scratch/.arp_session_log.json"
  (cd "$scratch" && /usr/bin/env bash -c "'$SKILL_RUN' --dry-run")
  actual_exit=$?

  # 4. Diff the produced session log against expected
  diff <(jq -S . "$actual_log") <(jq -S . "$fixture/expected-session-log.json") \
    || { echo "FAIL: session log drift"; exit 1; }

  expected_exit=$(cat "$fixture/expected-exit-code")
  [[ "$actual_exit" -eq "$expected_exit" ]] \
    || { echo "FAIL: exit $actual_exit, expected $expected_exit"; exit 1; }

  git worktree remove -f "$scratch"
  echo "== $name OK =="
done
echo "ALL GREEN"
```

The bash `run.sh` is ~60 LOC. The complexity lives in the fakes, not the runner.

## Interception Points

The skill currently does three dispatches:

| Dispatch | Tool | Intercept How |
|---|---|---|
| Codex × correctness | `Agent` tool → `codex:codex-rescue` | Replace the Agent call with a bash helper that reads fixture JSON. Requires a minimal shim script placed on `$PATH` that understands the fake-agent contract. |
| Codex × adversarial | same | same |
| Gemini × /ce:review | `Bash` tool → `gemini -p ...` | `$PATH`-shadow `gemini` with a fixture-replaying script. The post-dispatch WRITE-CHECK logic runs against real git state, which the fixture can steer by including `*.sh` side-effect scripts (e.g., `gemini-writes-a-file.sh` creates a tracked file change to trip the check). |

**Agent tool shim** is the tricky part — `codex:codex-rescue` is a Claude subagent, not a shell command. The harness can't intercept it at `$PATH` level. Options:

- **(a) Extract the prompt-writing step** into `.arp_stage_prompt.md` (already happens for Gemini) plus a sibling `.arp_dispatch.codex-<framing>.json` output file. Skill reads from the output file instead of calling Agent directly. Then the fake Agent just writes a fixture JSON to that path.
- **(b) Add a test-mode userConfig** (`testFixturesDir: "tests/fixtures/NN"`) that, when set, bypasses dispatch and reads canned outputs from the fixture dir. Adds one early return in the dispatch step.

Option **(b)** is less invasive and easier to argue for. Recommended.

## Coverage Matrix

Fixtures to ship with v1 of the harness:

| # | Fixture | Scenario | Blocker it unblocks |
|---|---|---|---|
| 01 | happy-path | 3 dispatches, 0 findings | baseline |
| 02 | write-check-tripped | Gemini "writes" a tracked file | WRITE-CHECK regression guard |
| 03 | fingerprint-collision | Two distinct bugs, same line, pre-rc2 formula would collide | Fingerprint rc2 lockdown |
| 04 | kill-switch | Same fingerprint after auto-fix applied | Loop-thrash rc1 guarantee |
| 05 | parse-error | Middle dispatch returns malformed JSON | Parse-error diagnostics (blocker #2) |
| 06 | ref-injection | `<ref>='$(rm -rf /)'` | Ref validation rc2 |
| 07 | quota-abort | Primary + fallback both 429, `ALLOW_FLASH_FALLBACK` unset | Flash gate rc2 |
| 08 | flock-contention | Two concurrent runs | flock guard rc2 |
| 09 | escalate | `maxIterations` hit with residual findings, `failOnError=true` | failOnError rc1 |
| 10 | dry-run | All of 01 but with `--dry-run` | No commit, no PR comment, no Edit calls |

## CI Plan (Phase 2)

Once the harness is green locally, wire into GitHub Actions:

```yaml
- uses: actions/checkout@v4
- run: bash tests/run.sh
```

No secrets needed. Matrix over bash 4 / 5 + macOS / Linux if portability becomes relevant. Block PR merge on harness failure.

## Open Questions

1. **How do fakes simulate `Agent` tool?** Answer pending the (a) vs (b) decision above. Recommended (b) via `testFixturesDir` userConfig.
2. **How fresh are cassettes?** A Codex prompt change should invalidate fixtures. Proposal: fixtures embed a `capture_commit` field; CI warns if the SKILL.md prompt sections changed since capture.
3. **Where do side-effect simulators live?** Option: `fixture/*/side-effects.sh` runs after the fake dispatch. For the WRITE-CHECK fixture, it creates a tracked file change. For a hang-simulation fixture, it sleeps past `timeout 600`.
4. **Do we replay real response bodies or synthesized minimal JSON?** Start synthesized (one finding per fixture). Graduate to real captures once we trust the basics.
5. **Is a `tests/` dir inside the plugin OK for Claude plugin marketplace?** Need to check marketplace packaging — if the plugin is shipped as a tarball, `tests/` may or may not be included. If not included, fixtures belong at repo root (`tests/fixtures/`) rather than `plugins/agent-review-pipeline/tests/`.

## Next Steps

1. Decide on interception point (Agent shim vs `testFixturesDir` userConfig). **Recommendation: `testFixturesDir`.**
2. Ship fixture `01-happy-path` as proof-of-concept. One fixture, one green run, wire into `tests/run.sh`.
3. Add fixtures `02` and `05` next — they cover the two most recent rc-surfaced regressions (WRITE-CHECK + parse error).
4. Tag rc4 once the first three fixtures pass in CI. That's the first rc with automated regression evidence.

## Why Spec First, Not Code First

Writing the fixtures requires agreeing on the interception model. Coding the runner before the model is chosen means rewriting the runner later. This spec narrows the design space; the follow-up PR can just pick option (a) or (b) and ship.
