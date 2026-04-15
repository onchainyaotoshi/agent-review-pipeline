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

set -u
TIMEOUT_SEC=30
MODEL="${ARP_DEFAULT_GEMINI_MODEL:-gemini-3-flash-preview}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      MODEL="$1"
      shift
      ;;
  esac
done

if ! command -v gemini >/dev/null 2>&1; then
  echo "probe-gemini: gemini CLI not on PATH. Install: npm i -g @google/gemini-cli" >&2
  exit 1
fi

echo "probe-gemini: model=${MODEL} timeout=${TIMEOUT_SEC}s"

OUT=$(timeout "${TIMEOUT_SEC}" gemini -m "${MODEL}" -p "respond: ok" -o text 2>&1)
RC=$?

if [[ $RC -eq 124 ]]; then
  echo "probe-gemini: TIMEOUT — no response in ${TIMEOUT_SEC}s. Likely server-cap exhausted; CLI is stuck in retry-backoff." >&2
  exit 3
fi

if echo "${OUT}" | grep -q "ModelNotFoundError"; then
  echo "probe-gemini: 404 ModelNotFound — '${MODEL}' is not a valid headless API model ID. Check 'gemini models list' or use -preview suffix." >&2
  exit 1
fi

if echo "${OUT}" | grep -qE "MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|429"; then
  if [[ $RC -eq 0 ]]; then
    echo "probe-gemini: OK after backoff (model returned content)" >&2
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

echo "probe-gemini: unexpected exit ${RC}" >&2
echo "${OUT}" | tail -10 >&2
exit "${RC}"
