# agent-review-pipeline

Multi-engine 5-stage code review pipeline for [Claude Code](https://claude.ai/code) with **Dual-Engine Consensus**. By default, it concurrently deploys **both** [Codex](https://github.com/openai/codex-plugin-cc) and [Gemini CLI](https://github.com/google-gemini/gemini-cli) to review full-stack PRs holistically, utilizing cross-engine validation to eliminate AI hallucinations.

## What It Does

Chains an intelligent, context-aware review process with **automatic fix-and-retry**, built for large PRs and enterprise codebases:

1. **Cross-Engine Consensus:** ARP submits your entire PR to BOTH Gemini (powered by `ce:review`) and Codex concurrently. If both engines independently flag the exact same bug on the same line, the bug's **Confidence Score** is boosted. Findings with low confidence are discarded, ensuring ARP only acts on verified issues.
2. **5-Stage Pipeline:**
   * **0. Context Setup** — Scans repo for rules (`CLAUDE.md`).
   * **1. Correctness Review** — Logic errors, null derefs, missing functions.
   * **2. Impact Analysis** — Backward compatibility and consumer breakage.
   * **3. Adversarial Review** — Edge cases, races, bypasses.
   * **4. Test Generation** — Proves the fix works by generating unit tests.
   * **5. Deliver & PR Report** — Autonomous git commits and `gh pr comment` summary.

## How It Differs from Manual Reviews & Other Agents

| Traditional Agent | ARP v4.1 (Consensus) |
|-------------------|----------------------|
| **Single AI Point of Failure:** Blindly trusts one LLM's hallucination. | **Cross-Engine Consensus:** Requires Gemini and Codex to agree (or have high confidence) to act. |
| **Silent Fixes:** Just edits files without proof. | **Test-Driven:** Forces unit test generation for every applied fix. |
| **Generic Advice:** Standard AI suggestions. | **Context Injected:** Reads your `CLAUDE.md` and applies your exact team standards. |

## Installation

```
/plugin marketplace add onchainyaotoshi/agent-review-pipeline
/plugin install agent-review-pipeline@agent-review-pipeline
/reload-plugins
```

## Usage

Review the current branch with the default dual-engine setup (Gemini + Codex):
```
/arp
```

Review a specific PR:
```
/arp 42
```

### Engine Selection

ARP defaults to running **BOTH** engines concurrently to maximize validation. You can explicitly choose a single engine:

```
/arp both                                # run Codex + Gemini on every file (Default)
/arp gemini                              # run only Gemini on all files
/arp codex                               # run only Codex on all files
```

## License

MIT
