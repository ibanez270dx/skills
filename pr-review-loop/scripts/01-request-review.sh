#!/usr/bin/env bash
# Request a Copilot review on a PR and verify the trigger landed.
#
# Single mechanism: GraphQL `requestReviewsByLogin` with
# botLogins:["copilot-pull-request-reviewer"]. See ../references/api-quirks.md.
#
# Usage:
#   01-request-review.sh --pr <n> [--owner <o> --repo <r>] [--verify-seconds <1..600>]
#
#   --pr <n>               The pull request number (required).
#   --owner/--repo         Optional; both or neither. Default: the current directory's
#                          repo, via `gh repo view`.
#   --verify-seconds <n>   Verification poll window (default 45).
#
# Success (exit 0, one line of compact JSON):
#   Status="InFlight"       Copilot is already a requested reviewer.
#   Status="TriggerLanded"  mutation submitted and verified by a NEW copilot_work_started
#                           event id.
# Failure (exit 1, message on stderr): the mutation failed, or no new event landed within
# --verify-seconds. Inspect the request/pending state before recovery. Never create
# a commit solely to trigger review.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' VERIFY=45
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --verify-seconds) need_value $# --verify-seconds; VERIFY=$2; shift 2 ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die "--pr is required."
require_int --pr "$PR"
require_int --verify-seconds "$VERIFY"
{ [ "$VERIFY" -ge 1 ] && [ "$VERIFY" -le 600 ]; } || die "--verify-seconds must be between 1 and 600 (got $VERIFY)."

require_tools
resolve_repo

# Prints "<id> <created_at>" for the newest copilot_work_started event on the PR, or "0"
# when there is none. Events are returned oldest-first and paginated at 100, so start at
# the last page (via the Link header's rel="last") instead of walking from the first, then
# search BACKWARD until a page contains a work-start event. The newest work-start need not
# be on the last page: if it is entry 100 and an unrelated event opens a new page, the last
# page has none, and stopping there would report "no event" for a trigger that landed.
latest_work_started() {
  local base="repos/$OWNER/$REPO/issues/$PR/events?per_page=100" resp headers body last_page=1
  GH_RETRIES=2 gh_capture api -i "$base"
  [ "$GH_EXIT" -eq 0 ] || die "events query failed: $GH_STDERR"
  resp=$(printf '%s\n' "$GH_STDOUT" | tr -d '\r')
  headers=$(printf '%s\n' "$resp" | sed -n '1,/^$/p')
  body=$(printf '%s\n' "$resp" | sed '1,/^$/d')
  # Link looks like: <https://api.github.com/...?per_page=100&page=4>; rel="last". The
  # param order isn't guaranteed, so match page=<n> inside the URL right before rel="last".
  last_page=$(printf '%s\n' "$headers" |
    sed -nE 's/.*[?&]page=([0-9]+)[^>]*>;[[:space:]]*rel="last".*/\1/p' | head -1)
  last_page=${last_page:-1}
  local pick='[.[] | select(.event == "copilot_work_started")] | sort_by(.id) | last
              | if . == null then empty else "\(.id) \(.created_at)" end'
  local p=$last_page found
  # Pages last_page .. 2 are fetched; page 1 is the response we already have in $body.
  while [ "$p" -gt 1 ]; do
    GH_RETRIES=2 gh_capture api "$base&page=$p"
    [ "$GH_EXIT" -eq 0 ] || die "events page $p query failed: $GH_STDERR"
    # A parse failure must fail the call. Returning "0" here would make the baseline look like
    # "no event yet", and a later good read would then count an EXISTING event as new and
    # report TriggerLanded for a trigger that never landed.
    found=$(printf '%s' "$GH_STDOUT" | jq -r "$pick") || die "events page $p returned unparseable JSON."
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    p=$((p - 1))
  done
  found=$(printf '%s' "$body" | jq -r "$pick") || die "events page 1 returned unparseable JSON."
  printf '%s\n' "${found:-0}"
}

# ---------- state: is Copilot currently requested? ----------
Q_STATE='
query($o:String!,$r:String!,$n:Int!){
  viewer{login}
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      id
      headRefOid
      state
      author{login}
      reviews(last:50){nodes{author{login}}}
      reviewRequests(first:100){nodes{requestedReviewer{__typename ... on Bot{login} ... on User{login} ... on Mannequin{login}}} pageInfo{hasNextPage endCursor}}
    }
  }
}'
state=$(gh_graphql_read "state query for $OWNER/$REPO PR #$PR" \
  -f query="$Q_STATE" -f o="$OWNER" -f r="$REPO" -F n="$PR")
PR_JSON=$(printf '%s' "$state" | jq -c '.data.repository.pullRequest // empty')
[ -n "$PR_JSON" ] || die "PR #$PR not found in $OWNER/$REPO."
PR_STATE=$(printf '%s' "$PR_JSON" | jq -r '.state')
[ "$PR_STATE" = OPEN ] || die "PR #$PR is not OPEN (state=$PR_STATE)."

VIEWER=$(printf '%s' "$state" | jq -r '.data.viewer.login // ""')
AUTHOR=$(printf '%s' "$PR_JSON" | jq -r '.author.login // ""')
VIEWER_IS_AUTHOR=false
{ [ -n "$VIEWER" ] && [ -n "$AUTHOR" ] && [ "$VIEWER" = "$AUTHOR" ]; } && VIEWER_IS_AUTHOR=true
COPILOT_HAS_REVIEWED=$(printf '%s' "$PR_JSON" | jq --arg rx "$COPILOT_LOGIN_REGEX" \
  '[.reviews.nodes[]? | select(.author and .author.login and (.author.login | test($rx; "i")))] | length > 0')
HEAD_OID=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid')
PR_NODE_ID=$(printf '%s' "$PR_JSON" | jq -r '.id // ""')
[ -n "$PR_NODE_ID" ] || die "Failed to resolve PR node id for $OWNER/$REPO PR #$PR from state query."

# Page through the rest of the requested reviewers so a PR with >100 of them can't make
# us miss Copilot and re-trigger a review that is already in flight.
REQUESTS=$(printf '%s' "$PR_JSON" | jq -c '.reviewRequests.nodes')
HAS_NEXT=$(printf '%s' "$PR_JSON" | jq -r '.reviewRequests.pageInfo.hasNextPage')
AFTER=$(printf '%s' "$PR_JSON" | jq -r '.reviewRequests.pageInfo.endCursor // ""')
Q_PAGE='
query($o:String!,$r:String!,$n:Int!,$after:String!){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      reviewRequests(first:100,after:$after){nodes{requestedReviewer{__typename ... on Bot{login} ... on User{login} ... on Mannequin{login}}} pageInfo{hasNextPage endCursor}}
    }
  }
}'
while [ "$HAS_NEXT" = true ]; do
  page=$(gh_graphql_read "reviewRequests page query for $OWNER/$REPO PR #$PR" \
    -f query="$Q_PAGE" -f o="$OWNER" -f r="$REPO" -F n="$PR" -f after="$AFTER")
  rr=$(printf '%s' "$page" | jq -c '.data.repository.pullRequest.reviewRequests')
  REQUESTS=$(jq -cn --argjson acc "$REQUESTS" --argjson add "$(printf '%s' "$rr" | jq -c '.nodes')" '$acc + $add')
  HAS_NEXT=$(printf '%s' "$rr" | jq -r '.pageInfo.hasNextPage')
  AFTER=$(printf '%s' "$rr" | jq -r '.pageInfo.endCursor // ""')
done
COPILOT_PENDING=$(printf '%s' "$REQUESTS" | jq --arg rx "$COPILOT_LOGIN_REGEX" \
  '[.[] | select(.requestedReviewer and .requestedReviewer.login and (.requestedReviewer.login | test($rx; "i")))] | length > 0')

# If Copilot is in requested_reviewers, a review is in flight by definition.
if [ "$COPILOT_PENDING" = true ]; then
  jq -cn --argjson n "$PR" --arg head "$HEAD_OID" \
    '{Status: "InFlight", PrNumber: $n, HeadOid: $head, Detail: "Copilot is currently in requested_reviewers; review is in flight."}'
  exit 0
fi

# We do NOT short-circuit on "already reviewed": re-requesting is a first-class flow, and
# the mutation handles initial-add and re-request identically.

# ---------- snapshot copilot_work_started BEFORE triggering ----------
# Compare the event's numeric `id` (monotonic); `created_at` is second-resolution and
# would collide if a new event landed in the same second.
BEFORE=$(latest_work_started)
BEFORE_ID=${BEFORE%% *}

# ---------- trigger via GraphQL requestReviewsByLogin ----------
# Why this path and not REST or `requestReviews`? Verified end-to-end:
#   - REST POST /pulls/{n}/requested_reviewers with reviewers:["Copilot"] -> 404. The REST
#     `reviewers` field accepts type=User only; bots are rejected.
#   - GraphQL `requestReviews` rejects bot node IDs at the schema level.
#   - `requestReviewsByLogin.botLogins` is the ONLY public path for bot reviewers; the
#     trade-off is that it requires repo Triage/Write.
#   - The UI refresh button uses a github.com Rails endpoint with a session cookie and
#     CSRF token that gh's OAuth token cannot satisfy.
MUTATION='mutation($p:ID!){requestReviewsByLogin(input:{pullRequestId:$p,botLogins:["copilot-pull-request-reviewer"]}){pullRequest{number}}}'
# No retry: a mutation whose response was lost must not be applied twice.
gh_capture api graphql -f query="$MUTATION" -f p="$PR_NODE_ID"

# Detect a permission failure on BOTH surfaces: usually `gh` exits non-zero with the
# message on stderr, but some GraphQL paths exit 0 with a top-level errors[] of
# type=FORBIDDEN.
PERM_RX='does not have (the )?correct permissions|forbidden|HTTP 403'
PERM_ERR=false
BODY_ERRORS=''
if [ "$GH_EXIT" -ne 0 ] && printf '%s' "$GH_STDERR" | grep -Eiq "$PERM_RX"; then PERM_ERR=true; fi
if [ -n "$GH_STDOUT" ] && printf '%s' "$GH_STDOUT" | jq -e . >/dev/null 2>&1; then
  BODY_ERRORS=$(printf '%s' "$GH_STDOUT" | jq -r '(.errors // []) | map(.message) | join("; ")')
  if printf '%s' "$GH_STDOUT" | jq -e --arg rx "$PERM_RX" \
    '(.errors // []) | any(.type == "FORBIDDEN" or ((.message // "") | test($rx; "i")))' >/dev/null 2>&1; then
    PERM_ERR=true
  fi
elif [ -n "$GH_STDOUT" ]; then
  warn "requestReviewsByLogin returned non-JSON output; falling back to the exit code/stderr."
fi

if [ "$PERM_ERR" = true ]; then
  RAW=$GH_STDERR
  [ -n "$RAW" ] || RAW=$BODY_ERRORS
  [ -n "$RAW" ] || RAW='(no message)'
  if [ "$VIEWER_IS_AUTHOR" = true ]; then
    SCENARIO='initial add'
    [ "$COPILOT_HAS_REVIEWED" = true ] && SCENARIO='re-request'
    die "Cannot trigger Copilot via public API in this scenario ($SCENARIO):
  - You are the PR author ($VIEWER) on $OWNER/$REPO PR #$PR.
  - You lack repo Triage/Write permission, so requestReviewsByLogin returns FORBIDDEN.
  - GitHub's public GraphQL schema has no other bot-reviewer mutation
    (verified: requestReviews rejects bot node IDs; no REST \`bot_reviewers\` field).
  - The UI's re-request button uses an internal endpoint not in the public API.

Recovery options (automatic review depends on repository configuration):
  1. UI: open the PR in a browser and click the refresh icon next to 'copilot-pull-request-reviewer'.
  2. If genuine in-scope fixes are already ready, push them normally; automatic
     review on push may be configured. Never create a commit solely to trigger review.

After triggering by either means, resume the loop with 02-check-review-status.sh.

Raw error: $RAW"
  fi
  die "GraphQL requestReviewsByLogin failed with a permission error: $RAW

Most likely causes:
  * Authenticated user lacks Triage / Write permission on the repo
    (run \`gh api repos/$OWNER/$REPO --jq .permissions\` to confirm; Read-only
    collaborators cannot request reviewers).
  * Copilot Code Review not enabled on the repo / account."
fi

if [ "$GH_EXIT" -ne 0 ]; then
  die "GraphQL requestReviewsByLogin failed: $GH_STDERR

Most likely causes:
  * Quiet-period after a recent dismissal of Copilot: wait and inspect pending state.
  * Copilot Code Review not enabled on the repo / account.
  * PR in a state that blocks bot review (draft, conflict, branch protection)."
fi

# A non-FORBIDDEN errors[] from an exit-0 response: surface it directly.
[ -z "$BODY_ERRORS" ] || die "GraphQL requestReviewsByLogin returned errors: $BODY_ERRORS"

# ---------- verify a NEW copilot_work_started event landed ----------
DEADLINE=$(($(date +%s) + VERIFY))
AFTER_ID=0 AFTER_TS='' LAST_ERR=''
VERIFY_ERR=$(mktemp "${TMPDIR:-/tmp}/pr-review-loop.XXXXXX")
while :; do
  # latest_work_started dies on a query failure; run it in a subshell so a transient
  # failure here is recorded and retried instead of aborting verification.
  if NOW=$(latest_work_started 2>"$VERIFY_ERR"); then
    LAST_ERR=''
    NOW_ID=${NOW%% *}
    if [ "$NOW_ID" -gt "$BEFORE_ID" ]; then
      AFTER_ID=$NOW_ID
      AFTER_TS=${NOW#* }
      break
    fi
  else
    LAST_ERR=$(cat "$VERIFY_ERR" 2>/dev/null || true)
  fi
  NOW_TS=$(date +%s)
  [ "$NOW_TS" -lt "$DEADLINE" ] || break
  REMAINING=$((DEADLINE - NOW_TS))
  SLEEP=5
  [ "$REMAINING" -ge "$SLEEP" ] || SLEEP=$REMAINING
  [ "$SLEEP" -ge 1 ] || SLEEP=1
  sleep "$SLEEP"
done
rm -f "$VERIFY_ERR"

if [ "$AFTER_ID" -eq 0 ]; then
  TAIL=''
  [ -z "$LAST_ERR" ] || TAIL="
  Last events-query error: $LAST_ERR"
  die "GraphQL mutation returned success but no new copilot_work_started event landed within $VERIFY seconds. The server may have silently dropped the request, or the events query kept failing transiently.
  Latest copilot_work_started event id before trigger: $BEFORE_ID
  HEAD: $HEAD_OID$TAIL

Inspect pending-review state and repository settings before retrying or requesting
manual re-review. Never create a commit solely to trigger review."
fi

jq -cn --argjson n "$PR" --arg head "$HEAD_OID" --arg ts "$AFTER_TS" \
  '{Status: "TriggerLanded", PrNumber: $n, HeadOid: $head, WorkStartedAt: $ts,
    Detail: "Triggered via GraphQL requestReviewsByLogin; copilot_work_started at \($ts)."}'
