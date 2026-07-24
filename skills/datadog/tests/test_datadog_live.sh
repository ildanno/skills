#!/usr/bin/env bash
set -euo pipefail

readonly SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELPER="$SKILL_DIR/scripts/datadog.sh"

if [[ "${DD_LIVE_TEST:-}" != 1 ]]; then
  echo "Set DD_LIVE_TEST=1 to run the read-only Datadog smoke test." >&2
  exit 2
fi

bash "$HELPER" verify | jq -e '.ok == true' >/dev/null
bash "$HELPER" dashboard list --limit 1 | jq -e '.ok == true' >/dev/null
echo "Datadog live read-only smoke test passed."
