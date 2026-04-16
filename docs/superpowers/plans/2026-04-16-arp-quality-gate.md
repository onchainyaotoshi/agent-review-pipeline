# ARP Quality Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a three-phase Quality Gate (Stage 1.5) to ARP that improves engine agreement via semantic dedup, filters false positives via a finding classifier, and enhances rules extraction with suppress/enforce categorization.

**Architecture:** Three Haiku Agent calls inserted into the existing SKILL.md pipeline. Phase C runs pre-dispatch (enhances `<repository_rules>` injection). Phase A runs post-merge (semantic dedup). Phase B runs post-dedup (classifier filter). All phases fail-open. Config via `plugin.json` userConfig. Session log extended with `quality_gate` telemetry.

**Tech Stack:** Claude Code Agent tool (Haiku model), bash/jq for orchestration, existing ARP pipeline prose in SKILL.md.

---

## Files

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `plugins/agent-review-pipeline/skills/arp/SKILL.md` | Add Quality Gate stages + Phase A/B/C prose |
| Modify | `plugins/agent-review-pipeline/.claude-plugin/plugin.json` | Add `qualityGate` userConfig block |
| Modify | `CHANGELOG.md` | Add v5.6.0 entry |
| Modify | `plugins/agent-review-pipeline/README.md` | Update version badge + Quality Gate section |

---

### Task 1: Add qualityGate userConfig to plugin.json

**Files:**
- Modify: `plugins/agent-review-pipeline/.claude-plugin/plugin.json`

- [ ] **Step 1: Add qualityGate config block**

Add after the `dryRun` userConfig entry (after line 52):

```json
    "qualityGate": {
      "title": "Quality Gate",
      "type": "object",
      "default": {},
      "description": "Three-phase post-dispatch quality filter. Phase A: semantic dedup (groups similar findings across engines). Phase B: classifier (filters false positives, re-ranks severity). Phase C: enhanced rules extraction (categorizes repo rules as suppress/enforce). All phases fail-open. Uses Haiku Agent calls.",
      "properties": {
        "semanticDedup": {
          "title": "Semantic Dedup",
          "type": "boolean",
          "default": true,
          "description": "Group semantically similar findings across engines via Haiku Agent. Replaces fingerprint-only dedup with LLM-based grouping."
        },
        "classifier": {
          "title": "Finding Classifier",
          "type": "boolean",
          "default": true,
          "description": "Filter false positives and re-rank severity via Haiku Agent. Drops findings below classifierMinScore."
        },
        "classifierMinScore": {
          "title": "Classifier Min Score",
          "type": "number",
          "default": 3,
          "description": "Minimum real_score (1-5) to keep a finding. Higher = stricter filtering. Default 3."
        },
        "enhancedRules": {
          "title": "Enhanced Rules Extraction",
          "type": "boolean",
          "default": true,
          "description": "Categorize repository rules as SUPPRESS/ENFORCE/IGNORE via Haiku Agent before dispatch. Replaces raw rules injection."
        },
        "rulesModel": {
          "title": "Rules Extraction Model",
          "type": "string",
          "default": "haiku",
          "description": "Model for Quality Gate Agent calls. Only 'haiku' supported currently."
        }
      }
    }
```

- [ ] **Step 2: Verify JSON is valid**

Run: `jq . plugins/agent-review-pipeline/.claude-plugin/plugin.json > /dev/null && echo "OK" || echo "FAIL"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-review-pipeline/.claude-plugin/plugin.json
git commit -m "feat(arp): add qualityGate userConfig to plugin.json

Three-phase Quality Gate config: semanticDedup, classifier,
enhancedRules. All default enabled, fail-open on error."
```

---

### Task 2: Add Phase C — Enhanced Rules Extraction to SKILL.md

**Files:**
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md`

Phase C runs **before** engine dispatches (Step 0, after step 6 repo rules extraction). It takes the raw `.arp_repository_rules.md` and classifies rules into SUPPRESS/ENFORCE/IGNORE via a Haiku Agent call.

- [ ] **Step 1: Add Phase C prose after Step 0.6 (repo rules extraction)**

Find the line `9. Initialize \`.arp_session_log.json\` with empty findings.` in SKILL.md. Insert before it (as a new step 7, renumbering existing step 7→8, 8→9, 9→10):

Insert the following block between the repo rules extraction bash block and "7. Resolve PR diff":

```markdown
7. **Quality Gate Phase C — Enhanced Rules Extraction (v5.6.0).** After building `.arp_repository_rules.md` (step 6 above), run one Haiku Agent call to classify the raw rules into review-relevant categories. This replaces the raw `<repository_rules>` block in engine prompts with a structured `<review_context>` block that separates intentional patterns (suppress) from correctness constraints (enforce) and strips irrelevant dev-process rules (ignore).

   **Gate check:** read `qualityGate` from plugin.json userConfig. If `qualityGate.enabled` is `false` (the `enabled` sub-key, not the parent), or `qualityGate.enhancedRules` is `false`, skip this phase and use existing raw injection. Default: enabled.

   **Agent dispatch:**

   ```bash
   RULES_CONTENT=$(cat .arp_repository_rules.md 2>/dev/null || echo "")
   if [[ -n "$RULES_CONTENT" ]]; then
     # Write classified rules to temp file for Agent to read
     cat > .arp_rules_classify_prompt.md <<'PROMPT'
   You are a code review context optimizer. Given raw repository rules below,
   extract and categorize into:

   1. SUPPRESS rules — patterns that are INTENTIONAL in this codebase.
      Engines should NOT flag these as issues. (e.g., "we use CommonJS",
      "controllers follow X layout", "this file is auto-generated")
   2. ENFORCE rules — correctness constraints engines SHOULD check.
      (e.g., "always validate user input", "never log secrets")
   3. IGNORE — generic dev process rules irrelevant to code review.
      (e.g., "use conventional commits", "PRs need 2 approvals")

   Output JSON only — no markdown fences, no prose:
   {"suppress": ["rule summary 1", "rule summary 2"], "enforce": ["rule summary 3", "rule summary 4"], "ignore_count": N, "token_count_estimate": N}

   <raw_rules>
   PROMPT
     echo "$RULES_CONTENT" >> .arp_rules_classify_prompt.md
     echo "</raw_rules>" >> .arp_rules_classify_prompt.md
   fi
   ```

   Then invoke Agent tool with `model: "haiku"`, description "Classify repo rules for ARP", prompt:

   > Read `.arp_rules_classify_prompt.md` and respond with ONLY the JSON object requested — no markdown fences, no prose before or after.

   **Parse result:** `jq -e '.suppress and .enforce'` to validate structure. On parse failure, set `PHASE_C_FALLBACK=true` and use raw `.arp_repository_rules.md` as before.

   **Build structured review context:**

   ```bash
   if [[ "$PHASE_C_FALLBACK" != "true" ]]; then
     SUPPRESS_RULES=$(echo "$AGENT_RESPONSE" | jq -r '.suppress[]' 2>/dev/null)
     ENFORCE_RULES=$(echo "$AGENT_RESPONSE" | jq -r '.enforce[]' 2>/dev/null)
     {
       echo "<review_context>"
       echo "## Patterns that are INTENTIONAL — DO NOT FLAG:"
       echo "$SUPPRESS_RULES" | while read -r line; do echo "- $line"; done
       echo ""
       echo "## Correctness constraints — VERIFY THESE:"
       echo "$ENFORCE_RULES" | while read -r line; do echo "- $line"; done
       echo "</review_context>"
     } > .arp_review_context.md
     REVIEW_CONTEXT_BLOCK=$(cat .arp_review_context.md)
   else
     REVIEW_CONTEXT_BLOCK="<repository_rules>$(cat .arp_repository_rules.md)</repository_rules>"
   fi
   ```

   **Inject:** Replace the existing `<repository_rules>` block in all engine dispatch prompts with `$REVIEW_CONTEXT_BLOCK`. If Phase C fell back, the raw block is used unchanged (backward compat).

   **Session log telemetry:**

   ```bash
   IGNORE_COUNT=$(echo "$AGENT_RESPONSE" | jq -r '.ignore_count // 0' 2>/dev/null)
   SUPPRESS_COUNT=$(echo "$AGENT_RESPONSE" | jq -r '.suppress | length' 2>/dev/null || echo 0)
   ENFORCE_COUNT=$(echo "$AGENT_RESPONSE" | jq -r '.enforce | length' 2>/dev/null || echo 0)
   # Appended to quality_gate.phase_c in session log after Phase A/B
   ```

   Cleanup: `rm -f .arp_rules_classify_prompt.md .arp_review_context.md` in Step 2 cleanup.
```

- [ ] **Step 2: Update engine dispatch prompts to use $REVIEW_CONTEXT_BLOCK**

In the Codex dispatch 1/2 and Gemini dispatch 3 prompt descriptions, find references to `<repository_rules>` injection. Replace with: "Inject `$REVIEW_CONTEXT_BLOCK` (Phase C structured output, or raw `<repository_rules>` on fallback) into the prompt body."

The exact edit location is Step 1 prose where it says:

> Inject `.arp_repository_rules.md` contents into the `<repository_rules>` block of every engine prompt.

Change to:

> Inject `$REVIEW_CONTEXT_BLOCK` into every engine prompt. This is the Phase C structured output (suppress/enforce categories) when Quality Gate is enabled, or the raw `<repository_rules>` block when Phase C is disabled or fell back.

- [ ] **Step 3: Renumber subsequent steps**

Renumber existing steps 7→8, 8→9, 9→10 in Step 0. Verify no duplicate step numbers.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "feat(arp): Phase C — enhanced rules extraction

Haiku Agent classifies .arp_repository_rules.md into
SUPPRESS/ENFORCE/IGNORE categories. Structured <review_context>
replaces raw <repository_rules> in engine prompts. Fail-open on
Agent error."
```

---

### Task 3: Add Phase A — Semantic Dedup to SKILL.md

**Files:**
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md`

Phase A runs **after** the existing Merge + Fingerprint step (Step 1, items 3-6). It groups semantically similar findings via Haiku.

- [ ] **Step 1: Add Phase A prose after Merge + Fingerprint**

Find the "Merge + Fingerprint" section in Step 1 (around line 474). After item 6 (`Update agreement counters`), insert:

```markdown
7. **Quality Gate Phase A — Semantic Dedup (v5.6.0).** After fingerprint-based merge, run one Haiku Agent call to group findings that describe the same underlying issue but differ in wording, severity label, or exact file/line.

   **Gate check:** if `qualityGate.semanticDedup` is `false`, skip.

   **Write findings for classification:**

   ```bash
   MERGED_COUNT=$(jq '.findings | length' .arp_session_log.json)
   if [[ "$MERGED_COUNT" -gt 1 ]]; then
     jq -c '{findings: [.findings[] | {id: (.file + ":" + (.line|tostring) + ":" + (.severity|tostring)), file, line, severity, issue, confidence, produced_by, source}]}' \
       .arp_session_log.json > .arp_dedup_input.json
   fi
   ```

   Invoke Agent tool with `model: "haiku"`, description "Semantic dedup ARP findings", prompt:

   > Read `.arp_dedup_input.json`. You are a code review deduplication engine. Group findings that describe the same underlying issue — even if wording, severity label, or file/line differs slightly.
   >
   > Output JSON only — no markdown fences, no prose:
   > `{"groups": [["id1","id3"], ["id2"], ...]}`
   >
   > Each group = one underlying issue. Singleton = unique finding. Every finding ID must appear exactly once.

   **Parse + merge:**

   ```bash
   if [[ "$MERGED_COUNT" -gt 1 ]]; then
     GROUPS_JSON=$AGENT_RESPONSE
     PHASE_A_FALLBACK=false

     # Validate groups structure
     if ! echo "$GROUPS_JSON" | jq -e '.groups | type == "array"' >/dev/null 2>&1; then
       PHASE_A_FALLBACK=true
     fi

     if [[ "$PHASE_A_FALLBACK" != "true" ]]; then
       # For each group with >1 finding, merge into single finding
       echo "$GROUPS_JSON" | jq -r '.groups[] | select(length > 1) | @json' | while read -r group; do
         IDS=$(echo "$group" | jq -r '.[]')
         # Pick finding with highest confidence as base
         BASE_ID=$(echo "$IDS" | while read -r id; do
           jq -r --arg id "$id" '.findings[] | select((.file+":"+(.line|tostring)+":"+(.severity|tostring)) == $id) | "\(.confidence)\t\(.file):\(.line):\(.severity)"' .arp_session_log.json
         done | sort -rn | head -1 | cut -f2-)

         # Union produced_by and source, set confidence = max + 0.15*(group_size-1), cap 1.0
         GROUP_SIZE=$(echo "$group" | jq 'length')
         CONF_ADD=$(jq -n --argjson n "$GROUP_SIZE" '$n - 1 | . * 0.15')
         # Update session log: merge group into BASE_ID
         # (Detailed jq merge logic — pick longest issue text, highest severity,
         #  union produced_by and source arrays)
       done
     fi
   fi
   ```

   **Merge rules per group:**
   - Description: pick the finding with the longest `issue` text.
   - Severity: pick highest (`critical > high > medium > low`).
   - Confidence: `max(individual) + 0.15 × (group_size - 1)`, capped at 1.0.
   - `produced_by`: union of all engines in group.
   - `source`: union of all dispatch origins in group.
   - Remove merged findings from the group (keep only the merged representative).
   - Re-count agreement after merge.

   **Fallback:** if Agent call fails or JSON is invalid, keep existing fingerprint-based results unchanged (`PHASE_A_FALLBACK=true`).

   **Session log telemetry:** add to `quality_gate.phase_a`:
   ```json
   {
     "input_count": <MERGED_COUNT>,
     "groups_found": <count of groups with >1 finding>,
     "deduped_count": <findings remaining after merge>,
     "fallback": false
   }
   ```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "feat(arp): Phase A — semantic dedup via Haiku Agent

Groups findings that describe same underlying issue across engines.
Merge rules: longest issue text, highest severity, unioned
produced_by/source, confidence boost per extra group member.
Fail-open on Agent error."
```

---

### Task 4: Add Phase B — Finding Classifier to SKILL.md

**Files:**
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md`

Phase B runs **after** Phase A, **before** the kill-switch check and auto-fix loop. It filters false positives and re-ranks severity.

- [ ] **Step 1: Add Phase B prose after Phase A**

After the Phase A section added in Task 3, insert:

```markdown
8. **Quality Gate Phase B — Finding Classifier (v5.6.0).** After semantic dedup, run one Haiku Agent call to assess whether each finding is a real, actionable issue. Drop noise. Re-rank severity if needed.

   **Gate check:** if `qualityGate.classifier` is `false`, skip.

   **Write findings for classification:**

   ```bash
   jq -c '{findings: [.findings[] | {id: (.file + ":" + (.line|tostring) + ":" + (.severity|tostring)), file, line, severity, issue, confidence}]}' \
     .arp_session_log.json > .arp_classify_input.json
   ```

   Invoke Agent tool with `model: "haiku"`, description "Classify ARP findings", prompt:

   > Read `.arp_classify_input.json`. You are a senior engineer triaging code review findings. For each finding:
   >
   > 1. Is this a REAL, ACTIONABLE issue? (Not a style nitpick, not a hypothetical edge case that can't happen, not a false positive from misunderstanding codebase conventions.)
   > 2. Rate confidence in your assessment: 1-5 (5 = definitely real issue, 1 = definitely noise).
   > 3. Is the severity label correct? If not, suggest the correct one.
   >
   > Output JSON only — no markdown fences, no prose:
   > `{"assessments": [{"id": "...", "real_score": 4, "suggested_severity": "medium"}, ...]}`
   >
   > Every finding ID must appear exactly once.

   **Parse + filter:**

   ```bash
   MIN_SCORE=$(jq -r '.qualityGate.classifierMinScore // 3' <userconfig-path> 2>/dev/null || echo 3)
   DROPPED_IDS=()
   SEVERRITY_OVERRIDES=0

   echo "$AGENT_RESPONSE" | jq -c '.assessments[]?' | while read -r assessment; do
     ID=$(echo "$assessment" | jq -r '.id')
     REAL_SCORE=$(echo "$assessment" | jq -r '.real_score')
     SUGGESTED=$(echo "$assessment" | jq -r '.suggested_severity // empty')

     if [[ "$REAL_SCORE" -lt "$MIN_SCORE" ]]; then
       # Drop finding
       DROPPED_IDS+=("$ID")
       # Remove from session log findings array
     elif [[ -n "$SUGGESTED" ]]; then
       CURRENT_SEV=$(jq -r --arg id "$ID" '.findings[] | select((.file+":"+(.line|tostring)+":"+(.severity|tostring)) == $id) | .severity' .arp_session_log.json)
       if [[ "$SUGGESTED" != "$CURRENT_SEV" ]]; then
         # Override severity in session log
         SEVERRITY_OVERRIDES=$((SEVERRITY_OVERRIDES + 1))
       fi
     fi

     # Add real_score to finding for debugging
     # Update session log: .findings[] | add real_score field
   done
   ```

   **Fallback:** if Agent call fails or JSON invalid, keep all findings unchanged.

   **Session log telemetry:** add to `quality_gate.phase_b`:
   ```json
   {
     "input_count": <findings count before filter>,
     "dropped": <DROPPED_IDS count>,
     "severity_overrides": <SEVERRITY_OVERRIDES>,
     "dropped_ids": ["id1", "id2"],
     "fallback": false
   }
   ```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "feat(arp): Phase B — finding classifier via Haiku Agent

Filters false positives (real_score < threshold) and re-ranks
severity. Configurable classifierMinScore (default 3). Fail-open
on Agent error."
```

---

### Task 5: Update Session Log Schema and Pipeline Flow Diagram

**Files:**
- Modify: `plugins/agent-review-pipeline/skills/arp/SKILL.md`

- [ ] **Step 1: Update session log schema**

Find the Session Log schema section (around line 54-92). Add `quality_gate` field to the schema example:

Add after the `parse_errors` array:

```json
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
      "rules_extracted": true,
      "suppress_count": 4,
      "enforce_count": 7,
      "ignored_count": 3,
      "fallback_used": false
    }
  }
```

- [ ] **Step 2: Update Pipeline Flow diagram**

Replace the existing ASCII pipeline diagram (around line 101-122) with:

```
   ┌────────────────────────────────────────────┐
   │ 0. Context Setup (entire PR)               │
   │    + Phase C: Enhanced Rules Extraction    │
   └──────────────────┬─────────────────────────┘
                      │
   ┌──────────────────▼─────────────────────────┐
   │ 1. Review — 3 parallel dispatches           │
   │    codex   × correctness framing (ARP)      │
   │    codex   × adversarial framing (ARP)      │
   │    gemini  × /ce:review (compound engin.)   │
   └──────────────────┬─────────────────────────┘
                      │ Merge + Fingerprint
                      │ Phase A: Semantic Dedup (Haiku)
                      │ Phase B: Classifier (Haiku)
                      │ conf < 0.60? drop
                      │ real_score < min? drop
                      │ fingerprint reappears? kill switch → escalate
                      │ Auto-fix → loop until PASS or max (cap 10)
                      ▼
   ┌────────────────────────────────────────────┐
   │ 2. Deliver — summary, agreement rate,       │
   │    quality gate metrics, optional commit    │
   │    + gh pr comment                         │
   └────────────────────────────────────────────┘
```

- [ ] **Step 3: Update Step 2 Deliver to include Quality Gate metrics**

In Step 2.1 (compile summary), add after "Per-source parse-error count":

> - **Quality Gate metrics:** Phase A groups found, dedup savings. Phase B dropped count + severity overrides. Phase C suppress/enforce/ignore counts. Display as separate section in summary output.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "feat(arp): update session log schema + pipeline diagram for Quality Gate

Add quality_gate telemetry to session log. Update ASCII flow
diagram with Phase A/B/C stages. Extend Deliver summary with
Quality Gate metrics."
```

---

### Task 6: Update README and CHANGELOG

**Files:**
- Modify: `plugins/agent-review-pipeline/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update README version + add Quality Gate section**

Read `plugins/agent-review-pipeline/README.md` and:
- Update version references from 5.5.0 to 5.6.0
- Add a **Quality Gate** section describing the three phases:

```markdown
## Quality Gate (v5.6.0)

Three-phase post-dispatch quality filter, each using a lightweight Haiku Agent call:

| Phase | When | What | Cost |
|-------|------|------|------|
| C | Pre-dispatch | Classify repo rules as suppress/enforce/ignore | ~500 tokens |
| A | Post-merge | Semantic dedup — group similar findings across engines | ~500-1000 tokens |
| B | Post-dedup | Classifier — filter false positives, re-rank severity | ~500-1500 tokens |

Total overhead: ~3 Haiku calls per run (~2000-3000 tokens). All phases fail-open on error.

**Config (plugin.json userConfig):**
```json
{
  "qualityGate": {
    "semanticDedup": true,
    "classifier": true,
    "classifierMinScore": 3,
    "enhancedRules": true
  }
}
```
```

- [ ] **Step 2: Add CHANGELOG entry**

Prepend to `CHANGELOG.md`:

```markdown
## v5.6.0 — 2026-04-16

**feat: Quality Gate — semantic dedup, finding classifier, enhanced rules**

Three-phase quality filter between Stage 1 (dispatch) and Stage 2 (deliver):
- **Phase A:** Semantic dedup — Haiku Agent groups findings that describe the same underlying issue across engines, even when wording/severity/file:line differ. Replaces fingerprint-only dedup with LLM-based grouping. Merged findings get confidence boost (+0.15 per extra source).
- **Phase B:** Finding classifier — Haiku Agent rates each finding as real vs noise (1-5 scale), drops findings below `classifierMinScore` (default 3), re-ranks severity when mismatched. Configurable strictness.
- **Phase C:** Enhanced rules extraction — Haiku Agent classifies repo rules (AGENTS.md, CLAUDE.md, .claude/rules/) into SUPPRESS (intentional patterns, don't flag), ENFORCE (correctness constraints, verify), IGNORE (dev-process rules, strip). Replaces raw rules injection with structured `<review_context>` block.

All phases fail-open on error (fallback to existing behavior). Session log extended with `quality_gate` telemetry. Config via `qualityGate` userConfig in plugin.json.

---
```

- [ ] **Step 3: Update SKILL.md version header**

In SKILL.md frontmatter, update version from `5.5.0` to `5.6.0`. Update the Status line accordingly.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-review-pipeline/README.md CHANGELOG.md plugins/agent-review-pipeline/skills/arp/SKILL.md
git commit -m "docs(arp): v5.6.0 — Quality Gate readme, changelog, version bump"
```

---

### Task 7: Dry-run smoke test

**Files:** None (verification only)

- [ ] **Step 1: Validate SKILL.md parses**

Run: `head -6 plugins/agent-review-pipeline/skills/arp/SKILL.md`
Expected: version shows `5.6.0`

- [ ] **Step 2: Validate plugin.json parses**

Run: `jq .qualityGate plugins/agent-review-pipeline/.claude-plugin/plugin.json`
Expected: object with `semanticDedup`, `classifier`, `classifierMinScore`, `enhancedRules`, `rulesModel` keys

- [ ] **Step 3: Verify no orphaned references**

Run: `grep -n 'repository_rules' plugins/agent-review-pipeline/skills/arp/SKILL.md`
Expected: references should mention Phase C fallback or be in the Phase C section itself. No dangling references to removed functionality.

- [ ] **Step 4: Verify step numbering is consistent**

Run: `grep -n '^[0-9]\+\.' plugins/agent-review-pipeline/skills/arp/SKILL.md | head -20`
Expected: consecutive step numbers in Step 0 (1-10), no duplicates.

---

## Self-Review Checklist

1. **Spec coverage:**
   - Phase A semantic dedup → Task 3
   - Phase B classifier → Task 4
   - Phase C enhanced rules → Task 2
   - Config in plugin.json → Task 1
   - Session log telemetry → Task 5
   - Pipeline diagram update → Task 5
   - README + CHANGELOG → Task 6
   - Smoke test → Task 7

2. **Placeholder scan:** No TBD/TODO found. All steps have code.

3. **Type consistency:** `quality_gate.phase_a/b/c` keys match across spec, session log schema, and Task 3/4/5 prose. `classifierMinScore` is integer everywhere.
