#!/usr/bin/env bash
# Deterministically count a PR's Copilot review rounds and flag whether the periodic recap
# gate is due. Read-only, except with --ack, which posts one PR comment.
#
# ONE job: compute the round number N for a PR from observable history (the count of review
# submissions authored by the Copilot Code Review bot) and report whether the recap
# circuit-breaker is due. Each top-of-loop trigger (01-request-review.sh) produces at least
# one Copilot review submission, so that count tracks the rounds. It is read from the GitHub
# API on every call, so it never depends on agent memory or an on-disk state file: the failure
# this skill was built to survive (an agent losing count across a long run and drifting for
# 156 rounds) can't happen when the count is derived.
#
# "Due" is derived from the PR too. A recap is due when the number of recap boundaries
# reached, floor(Round / interval), exceeds the number of recaps ACKNOWLEDGED. An
# acknowledgement is a PR comment from you carrying a hidden marker, posted by --ack. That
# makes the gate immune to a boundary being stepped over (an automatic review on push plus a
# requested one can take the count from 9 to 11, past 10): it stays due until the parent
# acknowledges it, and each recap leaves a visible record on the PR.
#
# This script decides nothing else: it doesn't stop the loop, enforce a cap, or pick a
# verdict. The parent agent owns the recap reasoning and the CONTINUE / REVERT-AND-SHIP /
# HAND-OFF verdict (see ../references/09-convergence.md), then records that it ran the recap
# with --ack.
#
# Usage:
#   09-review-round.sh --pr <n> [--owner <o> --repo <r>] [--recap-interval <n>]
#   09-review-round.sh --pr <n> --ack --body <recap>      (after running the recap gate)
#
#   --pr <n>              The pull request number (required).
#   --owner/--repo        Optional; both or neither. Default: the current directory's
#                         repo, via `gh repo view`.
#   --recap-interval <n>  Recap cadence in rounds (default 10: at 10, 20, 30, ...). A single
#                         named knob, so the cadence isn't a magic number duplicated in prose.
#   --ack                 Record that the recap gate was run: posts --body as a PR comment
#                         with a hidden marker. Fails if no recap is due, so it can't be
#                         double-counted.
#   --body <recap>        The recap to post with --ack (what the rounds were, the drift
#                         assessment, and the verdict). Required with --ack.
#
# Output (one line of compact JSON):
#   {"PrNumber","Owner","Repo","Round","RecapInterval","RecapsAcknowledged","RecapDue"}
#   (plus "Acknowledged":true after --ack, with the values AFTER the acknowledgement)
#   Round               count of Copilot Code Review submissions on the PR. Full pagination:
#                       every submission, NOT the most-recent-100 window 02 uses, so the
#                       count stays correct on exactly the long loops the gate exists to catch.
#   RecapsAcknowledged  recap acknowledgement comments from the authenticated user.
#   RecapDue            true iff floor(Round / RecapInterval) > RecapsAcknowledged.
#
# Parsing: round=$(printf '%s' "$snap" | grep -o '"Round":[0-9]*' | cut -d: -f2)
#          case $snap in *'"RecapDue":true'*) ... ;; esac

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' INTERVAL=10 ACK=false BODY='' HAVE_BODY=false
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --recap-interval) need_value $# --recap-interval; INTERVAL=$2; shift 2 ;;
    --ack) ACK=true; shift ;;
    --body) need_value $# --body; BODY=$2; HAVE_BODY=true; shift 2 ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die "--pr is required."
require_int --pr "$PR"
require_int --recap-interval "$INTERVAL"
[ "$INTERVAL" -ge 1 ] || die "--recap-interval must be at least 1."
if [ "$ACK" = true ]; then
  { [ "$HAVE_BODY" = true ] && [ -n "$BODY" ]; } || die "--ack requires a non-empty --body (the recap to post)."
elif [ "$HAVE_BODY" = true ]; then
  die "--body is only used with --ack."
fi

require_tools
make_workdir
resolve_repo
resolve_me

# Walk ALL reviews (full pagination). Counting is order-independent, so forward
# pagination is sufficient.
QUERY='
query($o:String!,$r:String!,$n:Int!,$after:String){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      reviews(first:100, after:$after){
        pageInfo{endCursor hasNextPage}
        nodes{author{login}}
      }
    }
  }
}'

ROUND=0 AFTER=''
while :; do
  if [ -n "$AFTER" ]; then
    data=$(gh_graphql_read "reviews count for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f o="$OWNER" -f r="$REPO" -F n="$PR" -f after="$AFTER")
  else
    data=$(gh_graphql_read "reviews count for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f o="$OWNER" -f r="$REPO" -F n="$PR")
  fi
  page=$(printf '%s' "$data" | jq -c '.data.repository.pullRequest.reviews // empty')
  [ -n "$page" ] || die "PR #$PR not found in $OWNER/$REPO (reviews page)."
  count=$(printf '%s' "$page" | jq --arg rx "$COPILOT_LOGIN_REGEX" \
    '[.nodes[] | select(.author and .author.login and (.author.login | test($rx; "i")))] | length')
  ROUND=$((ROUND + count))
  [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = true ] || break
  AFTER=$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')
done

# Recaps already acknowledged: PR comments from us carrying the hidden marker. The marker
# prefix is shared with 08's hand-off marker's naming convention but is distinct from it.
RECAP_MARKER_PREFIX='<!-- pr-review-loop:recap'
COMMENTS_QUERY='
query($o:String!,$r:String!,$n:Int!,$after:String){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      issueComments: comments(first:100, after:$after){
        pageInfo{endCursor hasNextPage}
        nodes{author{login} body}
      }
    }
  }
}'
count_acks() {
  local after='' page n total=0
  while :; do
    if [ -n "$after" ]; then
      data=$(gh_graphql_read "PR comments for $OWNER/$REPO PR #$PR" \
        -f query="$COMMENTS_QUERY" -f o="$OWNER" -f r="$REPO" -F n="$PR" -f after="$after")
    else
      data=$(gh_graphql_read "PR comments for $OWNER/$REPO PR #$PR" \
        -f query="$COMMENTS_QUERY" -f o="$OWNER" -f r="$REPO" -F n="$PR")
    fi
    printf '%s' "$data" | jq -c '.data.repository.pullRequest.issueComments // empty' >"$WORK/page.json"
    [ -s "$WORK/page.json" ] || die "PR #$PR not found in $OWNER/$REPO (comments page)."
    n=$(jq --arg me "$ME" --arg m "$RECAP_MARKER_PREFIX" \
      '[.nodes[] | select((.author.login // "") == $me and ((.body // "") | contains($m)))] | length' "$WORK/page.json")
    total=$((total + n))
    [ "$(jq -r '.pageInfo.hasNextPage' "$WORK/page.json")" = true ] || break
    after=$(jq -r '.pageInfo.endCursor' "$WORK/page.json")
  done
  printf '%s\n' "$total"
}
ACKED=$(count_acks)

# Due when more recap boundaries have been reached than recaps acknowledged. Deriving it from
# the count of boundaries (not "is the count exactly a multiple") means a boundary that two
# reviews landing at once stepped over is still due, and stays due until acknowledged.
BOUNDARIES=$((ROUND / INTERVAL))
RECAP_DUE=false
[ "$BOUNDARIES" -le "$ACKED" ] || RECAP_DUE=true

ACKNOWLEDGED=''
if [ "$ACK" = true ]; then
  [ "$RECAP_DUE" = true ] ||
    die "No recap is due on PR #$PR (round $ROUND, interval $INTERVAL, $ACKED already acknowledged); not posting an acknowledgement."
  # A mutation: never auto-retried.
  gh_capture pr comment "$PR" --repo "$OWNER/$REPO" --body "$BODY

$RECAP_MARKER_PREFIX round=$ROUND -->"
  [ "$GH_EXIT" -eq 0 ] || die "posting the recap acknowledgement failed (exit $GH_EXIT): $GH_STDERR"
  ACKED=$((ACKED + 1))
  RECAP_DUE=false
  [ "$BOUNDARIES" -le "$ACKED" ] || RECAP_DUE=true
  ACKNOWLEDGED=true
fi

jq -cn --argjson n "$PR" --arg o "$OWNER" --arg r "$REPO" \
  --argjson round "$ROUND" --argjson interval "$INTERVAL" \
  --argjson acked "$ACKED" --argjson due "$RECAP_DUE" --arg ack "$ACKNOWLEDGED" '
  {PrNumber: $n, Owner: $o, Repo: $r, Round: $round, RecapInterval: $interval,
   RecapsAcknowledged: $acked, RecapDue: $due}
  + (if $ack == "true" then {Acknowledged: true} else {} end)'

