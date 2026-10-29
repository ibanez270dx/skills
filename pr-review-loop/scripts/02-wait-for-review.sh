#!/usr/bin/env bash
# Wait read-only for a newer Copilot review at the expected published HEAD.
#
# Usage:
#   02-wait-for-review.sh --pr <n> --baseline <timestamp-or-empty> --head <oid>
#     [--owner <o> --repo <r>] [--interval-seconds <n>] [--timeout-seconds <n>]
#
# Defaults: interval 180 seconds, timeout 1200 seconds. The deadline is checked
# between API calls; a running request may extend elapsed time beyond it.
# Emits one JSON object: {WaitStatus, ElapsedSeconds, Snapshot}.
# Exit 0: ready (newer review at expected HEAD and none pending; may have findings).
# Exit 124: timeout. Exit 3: head-changed or pr-closed. Exit 1: invalid input/API error.
# Never requests review, edits code, pushes, or posts comments.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' BASELINE='' BASELINE_SET=false EXPECTED_HEAD=''
INTERVAL=180 TIMEOUT=1200
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --baseline) need_value $# --baseline; BASELINE=$2; BASELINE_SET=true; shift 2 ;;
    --head) need_value $# --head; EXPECTED_HEAD=$2; shift 2 ;;
    --interval-seconds) need_value $# --interval-seconds; INTERVAL=$2; shift 2 ;;
    --timeout-seconds) need_value $# --timeout-seconds; TIMEOUT=$2; shift 2 ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die '--pr is required.'
require_int --pr "$PR"
[ "$BASELINE_SET" = true ] || die '--baseline is required (use an empty string for no prior review).'
[ -n "$EXPECTED_HEAD" ] || die '--head is required.'
for value in "$INTERVAL" "$TIMEOUT"; do
  # Bounded decimal values avoid Bash octal interpretation and arithmetic overflow.
  case $value in
    '' | *[!0-9]* | 0* | ???????*) die 'interval and timeout must be integers between 1 and 999999 seconds.' ;;
  esac
done
require_tools
if [ -n "$BASELINE" ]; then
  jq -en --arg t "$BASELINE" '$t | fromdateiso8601' >/dev/null 2>&1 ||
    die '--baseline must be an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) or empty.'
fi
resolve_repo
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
make_workdir
SECONDS=0

finish() {
  jq -cn --arg status "$1" --argjson elapsed "$SECONDS" \
    --slurpfile snapshot "$WORK/snapshot.json" \
    '{WaitStatus:$status, ElapsedSeconds:$elapsed, Snapshot:$snapshot[0]}'
  exit "$2"
}

while :; do
  "$SCRIPT_DIR/02-check-review-status.sh" --pr "$PR" --owner "$OWNER" --repo "$REPO" \
    >"$WORK/snapshot.json" || die 'Copilot wait failed: status check failed; inspect the diagnostic above.'
  state=$(jq -r '.State' "$WORK/snapshot.json")
  [ "$state" = OPEN ] || finish pr-closed 3
  head=$(jq -r '.HeadOid' "$WORK/snapshot.json")
  [ "$head" = "$EXPECTED_HEAD" ] || finish head-changed 3

  if jq -e --arg baseline "$BASELINE" '
    .ReviewAtHead == true and .CopilotPending == false and
    (.LatestCopilotReview.submittedAt // "") > $baseline
  ' "$WORK/snapshot.json" >/dev/null; then
    finish ready 0
  fi
  remaining=$((TIMEOUT - SECONDS))
  [ "$remaining" -gt 0 ] || finish timeout 124
  delay=$INTERVAL
  [ "$delay" -le "$remaining" ] || delay=$remaining
  sleep "$delay"
done
