# ARP Quality Gate — Design Spec

**Date:** 2026-04-16
**Version:** 1.0
**Status:** Draft

## Problem

ARP v5.5.0 dual-engine pipeline produces findings with two quality gaps:

1. **Low engine agreement** — Gemini and Codex find different issues on same code. Fingerprint-based dedup (`sha1(file:line:severity:normalize(issue):sha1(fix_code[:200]))`) misses semantic overlap because different wording/formatting produces different fingerprints.
2. **Too many false positives** — Both engines produce noise (style nitpicks, inapplicable edge cases). No post-processing filter validates whether findings are real, actionable issues.

## Solution

Add a **Quality Gate** (Stage 1.5) between existing Stage 1 (dispatch + merge) and Stage 2 (deliver). Three phases, each independently toggleable:

```
Stage 1 (existing)          Stage 1.5 (new)              Stage 2 (existing)
┌─────────────┐    ┌─────────────────────────┐    ┌──────────────┐
│ Codex ×2    │    │ Phase C: Context inject  │    │ Auto-fix     │
│ Gemini ×1   │───▶│ Phase A: Semantic Dedup  │───▶│ Summary      │
│ (3 findings)│    │ Phase B: Classifier      │    │ Commit/PR    │
└─────────────┘    └─────────────────────────┘    └──────────────┘
```

**Phase C runs pre-dispatch** (inject context into engine prompts).
**Phase A runs post-merge** (semantic dedup of merged findings).
**Phase B runs post-dedup** (filter + re-rank).

---

## Phase A: Semantic Dedup

### When

After merge/fingerprint step in Stage 1, before confidence scoring.

### How

1. Collect all findings from all dispatches.
2. Batch into one LLM call with this prompt:

```
You are a code review deduplication engine. Given N findings below,
group findings that describe the same underlying issue — even if
wording, severity label, or file/line differs slightly.

Output JSON only:
{"groups": [[finding_id_1, finding_id_3], [finding_id_2], ...]}

Each group = one underlying issue. Singleton = unique finding.

<findings>
{all findings as JSON}
</findings>
```

3. For each group with >1 finding: merge into single finding.
   - Description: pick longest/most detailed.
   - Severity: pick highest.
   - Confidence: `max(individual) + 0.15 × (group_size - 1)`, capped at 1.0.
   - `produced_by`: union of all engines in group.
   - `source`: union of all dispatch origins in group.

### Model

Haiku (cheap, fast, sufficient for grouping task).

### Cost

~500-1000 tokens per call. Negligible.

### Fallback

If LLM call fails or returns invalid JSON, fall back to existing fingerprint dedup. Log parse error in `.arp_session_log.json`.

---

## Phase B: Finding Classifier

### When

After Phase A, before kill-switch and auto-fix loop.

### How

1. Batch deduped findings into one LLM call:

```
You are a senior engineer triaging code review findings. For each finding:

1. Is this a REAL, ACTIONABLE issue? (Not a style nitpick, not a hypothetical
   edge case that can't happen, not a false positive from misunderstanding
   the codebase conventions.)
2. Rate confidence in your assessment: 1-5 (5 = definitely real, 1 = definitely noise).
3. Is the severity label correct? If not, suggest the correct one.

Output JSON only:
{"assessments": [
  {"id": "finding_1", "real_score": 4, "suggested_severity": "medium"},
  ...
]}

<findings>
{deduped findings as JSON}
</findings>

<project_context>
{content from arp.context.md if exists}
</project_context>
```

2. Apply filters:
   - `real_score < 3` → drop finding.
   - If `suggested_severity` differs from original → override.
   - Add `real_score` to finding in session log for debugging.

### Model

Haiku.

### Cost

~500-1500 tokens per call, depends on finding count.

### Config

```json
{
  "qualityGate": {
    "classifierMinScore": 3
  }
}
```

Default: 3. Range: 1-5. Higher = stricter filtering.

### Fallback

If LLM call fails, keep all findings (fail-open). Log warning.

---

## Phase C: Domain Context Injection

### When

Pre-flight (Step 0), before any engine dispatch.

### How

1. Look for `arp.context.md` in repo root.
2. If exists, read contents.
3. If not, check for `CLAUDE.md` and extract any `## Conventions` or `## Architecture` sections.
4. Inject into each engine's dispatch prompt as `<domain_context>` block:

```
<domain_context>
Project-specific context. Patterns described here are INTENTIONAL —
do not flag them as issues unless there's an actual bug.

{content}
</domain_context>
```

5. This context travels with the diff and repository_rules in each engine prompt.

### File Format: `arp.context.md`

```markdown
# ARP Domain Context

## Intentional Patterns
- Express controller layout uses X pattern — this is correct
- Error handling follows project convention Y
- File Z is auto-generated — skip review

## Known Constraints
- Must support Node 18+
- Database is read-only replica, no write operations expected

## Severity Overrides
- All dependency updates: LOW (automated by Dependabot)
- Test-only changes: reduce severity by 1 level
```

### Config

```json
{
  "qualityGate": {
    "contextFile": "arp.context.md"
  }
}
```

### Cost

Token overhead on dispatch prompts (not additional LLM calls). Estimated +200-500 tokens per dispatch.

---

## Configuration

All three phases controlled via `plugin.json` userConfig:

```json
{
  "qualityGate": {
    "enabled": true,
    "semanticDedup": true,
    "classifier": true,
    "classifierMinScore": 3,
    "contextInjection": true,
    "contextFile": "arp.context.md"
  }
}
```

- `enabled: false` → skip entire Quality Gate (backward compat).
- Individual phase toggles for incremental rollout.
- Defaults: all enabled, `classifierMinScore: 3`, `contextFile: "arp.context.md"`.

---

## Session Log Changes

Add to `.arp_session_log.json`:

```json
{
  "quality_gate": {
    "phase_a": {
      "input_count": 12,
      "groups_found": 4,
      "deduped_count": 8,
      "fallback": false
    },
    "phase_b": {
      "input_count": 8,
      "dropped": 3,
      "severity_overrides": 2,
      "dropped_ids": ["finding_5", "finding_9", "finding_11"],
      "fallback": false
    },
    "phase_c": {
      "context_file": "arp.context.md",
      "context_tokens_estimate": 340,
      "fallback_used": false
    }
  }
}
```

---

## Implementation Approach

ARP is a prompt-driven skill (no compiled code). All three phases are implemented as bash-wrapped LLM calls embedded in SKILL.md prose, same pattern as existing dispatch steps.

### LLM Call Pattern

Since ARP runs inside Claude Code, the Quality Gate uses the **Agent tool** to dispatch lightweight Haiku calls (no raw curl needed):

1. ARP writes merged findings to `.arp_merged_findings.json`.
2. SKILL.md instructs the orchestrator to invoke `Agent` with `model: "haiku"` for each phase.
3. Agent reads findings file, runs the dedup/classify prompt, returns structured JSON.
4. Orchestrator parses result and continues pipeline.

This leverages Claude Code's built-in tool system — no API key management, no curl, no auth concerns.

### Error Handling

- Phase A/B: fail-open on API error (keep existing findings, log warning).
- Phase C: silently skip if context file missing.

---

## Success Metrics

1. **Agreement rate increase:** baseline measurement from current session logs, target +30%.
2. **False positive reduction:** track `dropped` count from Phase B, survey user satisfaction.
3. **No regression:** all findings that Phase B drops should be confirmed as noise by manual review.
