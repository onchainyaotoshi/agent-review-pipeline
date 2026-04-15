# Contributing

Thanks for considering a contribution to `agent-review-pipeline`. This project is currently **5.0.0-rc1** — design and docs are complete, but the prompt-driven orchestration has not been end-to-end tested. Expect rough edges.

## Project Layout

```
.
├── .claude-plugin/marketplace.json        # Marketplace manifest
├── plugins/agent-review-pipeline/
│   ├── .claude-plugin/plugin.json         # Plugin manifest + userConfig
│   ├── README.md                          # User-facing docs
│   └── skills/arp/SKILL.md                # Canonical pipeline spec
├── README.md                              # Top-level overview
├── CHANGELOG.md                           # Release notes
├── LICENSE                                # MIT
└── CONTRIBUTING.md                        # This file
```

The **canonical source of truth** for pipeline behavior is `plugins/agent-review-pipeline/skills/arp/SKILL.md`. Keep all READMEs in sync with it.

## Before You Open a PR

1. **Read the canonical SKILL.md first.** All behavior claims in READMEs should be traceable to a step in SKILL.md.
2. **Update all three READMEs together** (root, plugin, and SKILL.md frontmatter description) for any behavior change. Doc drift is the #1 regression risk — there's no runtime to catch it.
3. **Bump the version** in all three places (`plugin.json`, `marketplace.json`, `SKILL.md` frontmatter) using [semver](https://semver.org/). Pre-release suffixes (`-rc1`, `-beta.2`) are encouraged for unverified behavior.
4. **Add a CHANGELOG entry** under a new `## X.Y.Z — YYYY-MM-DD` heading with Breaking / Added / Changed / Removed sections.
5. **Do not commit `.arp_*` artifacts.** They're gitignored — if they show up in `git status`, delete them.

## Design Principles

- **Prompt-driven, not runtime-driven.** The plugin is currently a Claude skill that describes behavior in natural language. Claude invoking the skill executes the steps. Avoid adding runtime dependencies (Node scripts, etc.) until a dedicated runtime-rewrite branch lands.
- **Asymmetric dispatch.** Codex gets ARP-authored prompts; Gemini gets its own `/ce:review` pipeline. Don't duplicate framing work.
- **Safe defaults.** `autoCommit` and `postPrComment` are `false` by default. `maxIterations` is capped at 10. These exist because LLM agents can silently spend money and push changes.
- **Fingerprint-based idempotency.** Findings are identified by `sha1(file:line:severity:normalize(issue):sha1(fix_code[:200]))`. Never rely on LLM-generated IDs.

## Known Production Blockers (see CHANGELOG)

The following need a runtime orchestrator (not prompt-driven) before this plugin is truly production-grade:

- Deterministic fingerprint computation
- Session log concurrency safety (file locks — partially addressed in rc2 via flock)
- LLM-side cost pre-estimate
- In-memory dispatch buffer scrubbing (PR-comment, parse-error artifacts, and session log on rotation all scrubbed in rc5-rc7; in-memory buffers between scrub points need a runtime rewrite)
- Integration test harness (draft spec at `docs/specs/integration-test-harness.md`; implementation deferred)

Contributions toward these are welcome. Open an issue first to align on approach.

## License

By contributing, you agree your work is licensed under MIT (same as the project).
