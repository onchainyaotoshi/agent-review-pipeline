#!/usr/bin/env bash
# probe-gemini.sh — verify Gemini model availability before /arp dispatch.
#
# Why: /arp Gemini side calls `gemini -p ... -m <model>`. Server-cap on Pro
# deployments is volatile; a 30s headless probe tells you in advance whether
# the dispatch will succeed or burn ~10 min of your timeout budget on retry
# storms. See plugins/agent-review-pipeline/skills/arp/SKILL.md model cascade.
#
# Usage:
#   scripts/probe-gemini.sh                       # probe default model
#   scripts/probe-gemini.sh gemini-3.1-pro-preview
#   scripts/probe-gemini.sh -m gemini-3-flash-preview
#
# Exit codes:
#   0  model returned a response within the budget
#   1  model returned 404 ModelNotFoundError (invalid headless model name)
#   2  model returned 429 / capacity exhausted within the budget
#   3  timed out without any response (likely server-cap exhaustion + backoff)
#   4  invalid arguments or other usage error
#
# Note: stdout/stderr are kept separate so that error-pattern matching only
# scans gemini's stderr — prevents false positives when the model legitimately
# echoes "429" or "MODEL_CAPACITY_EXHAUSTED" in its response text.

set -u
TIMEOUT_SEC=30
MAX_OUT_BYTES=65536
DEFAULT_MODEL="gemini-3-flash-preview"
MODEL="${ARP_DEFAULT_GEMINI_MODEL:-$DEFAULT_MODEL}"
if [[ -z "${MODEL// }" ]]; then
  echo "probe-gemini: ARP_DEFAULT_GEMINI_MODEL is blank, using ${DEFAULT_MODEL}" >&2
  MODEL="$DEFAULT_MODEL"
fi

usage() {
  cat <<'USAGE'
probe-gemini.sh — verify Gemini model availability before /arp dispatch.

Usage:
  scripts/probe-gemini.sh                       # probe default model
  scripts/probe-gemini.sh gemini-3.1-pro-preview
  scripts/probe-gemini.sh -m gemini-3-flash-preview

Exit codes:
  0  model returned a response within the budget
  1  model returned 404 ModelNotFoundError (invalid headless model name)
  2  model returned 429 / capacity exhausted within the budget
  3  timed out without any response (likely server-cap + retry backoff)
  4  invalid arguments or usage error
USAGE
}

POSITIONAL_SEEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "probe-gemini: -m requires a model argument" >&2
        exit 4
      fi
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "probe-gemini: unknown option: $1" >&2
      exit 4
      ;;
    *)
      if [[ $POSITIONAL_SEEN -eq 1 ]]; then
        echo "probe-gemini: expected at most one positional model argument" >&2
        exit 4
      fi
      POSITIONAL_SEEN=1
      MODEL="$1"
      shift
      ;;
  esac
done

if ! command -v gemini >/dev/null 2>&1; then
  echo "probe-gemini: gemini CLI not on PATH. Install: npm i -g @google/gemini-cli" >&2
  exit 4
fi

echo "probe-gemini: model=${MODEL} timeout=${TIMEOUT_SEC}s"

ERR_FILE=$(mktemp -t probe-gemini-err.XXXXXX)
trap 'rm -f "$ERR_FILE"' EXIT

OUT=$(timeout "${TIMEOUT_SEC}" gemini -m "${MODEL}" -p "respond: ok" -o text 2>"$ERR_FILE" | head -c "$MAX_OUT_BYTES")
RC=$?
ERR=$(head -c "$MAX_OUT_BYTES" "$ERR_FILE" 2>/dev/null || true)

if [[ $RC -eq 124 ]]; then
  echo "probe-gemini: TIMEOUT — no response in ${TIMEOUT_SEC}s. Likely server-cap exhausted; CLI is stuck in retry-backoff." >&2
  exit 3
fi

# Error-pattern matching runs over stderr only — gemini's stdout is the
# model's actual response, which can legitimately contain '429' as text.
if echo "${ERR}" | grep -q "ModelNotFoundError"; then
  echo "probe-gemini: 404 ModelNotFound — '${MODEL}' is not a valid headless API model ID. Check 'gemini models list' or use -preview suffix." >&2
  exit 1
fi

if echo "${ERR}" | grep -qE "MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|status: 429"; then
  if [[ $RC -eq 0 ]]; then
    echo "probe-gemini: OK after backoff (model returned content despite intermittent 429)" >&2
    echo "${OUT}" | tail -5
    exit 0
  fi
  echo "probe-gemini: 429 capacity exhausted; CLI gave up before timeout. Try again later or pick a different model." >&2
  exit 2
fi

if [[ $RC -eq 0 ]]; then
  echo "probe-gemini: OK"
  echo "${OUT}" | tail -5
  exit 0
fi

# Collapse unknown gemini exit codes to a generic failure so we never conflate
# them with this script's defined 0/1/2/3 contract.
echo "probe-gemini: unexpected exit from gemini (rc=${RC})" >&2
echo "${ERR}" | tail -10 >&2
exit 4
