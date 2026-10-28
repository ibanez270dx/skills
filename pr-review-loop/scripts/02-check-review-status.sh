#!/usr/bin/env bash
# Single-shot snapshot of a PR's Copilot review state (read-only). Emits one line of
# compact JSON and exits 0; any failure exits non-zero with a message on stderr.
#
# Usage:
#   02-check-review-status.sh --pr <n> [--owner <o> --repo <r>] [--single-iteration]
#
#   --pr <n>             The pull request number (required).
#   --owner/--repo       Optional; both or neither. Default: the current directory's
#                        repo, via `gh repo view`.
#   --single-iteration   The agent has decided to drive this PR as a single iteration
#                        (typically because 01-request-review.sh failed with a
#                        Copilot-disabled error). Convergence then ignores the
#                        stale-review checks (ReviewAtHead / NoNewComments), which can
#                        never become true when the trigger is intentionally skipped,
#                        and depends solely on OpenThreadsAwaitingReply == 0.
#
# Output fields:
#   PrNumber, Owner, Repo, HeadOid, State
#   LatestCopilotReview   {state, submittedAt, commitOid, bodyHead} or null if no Copilot
#                         review is in the most recent 100 reviews (treat null as "no
#                         recent review", not "never reviewed")
#   ReviewAtHead          true iff the latest Copilot review's commit == HeadOid
#   NoNewComments         true iff the latest review body is clean: it says
#                         "**0 open findings**" (current format) or "generated no new
#                         comments" / "generated 0 comments" (older format) AND lists no
#                         "Previously missed" findings
#   PreviouslyMissedCount findings Copilot lists in the review body under "Previously
#                         missed (N)". They are NOT threads, so 03-list-open-threads.sh
#                         cannot see them; read the review body and handle them like
#                         threads (no thread to resolve: reply with a PR comment)
#   ReviewVerdict         the verdict in the latest Copilot review's header, e.g. "Approved",
#                         "Changes recommended", "Needs a closer look" (null if absent)
#   ReviewSummary         the sentence under that header (null if absent). "Needs a closer
#                         look" often asks a HUMAN to confirm something (e.g. production
#                         preflight checks) even with 0 findings. That is a hand-off, not
#                         agent work, so it does not block Converged, but the agent MUST
#                         surface it to the user verbatim in its completion message.
#   OpenThreadCount       unresolved review threads from all reviewers; informational,
#                         convergence does NOT require it to be zero
#   OpenThreadsAwaitingReply  open threads whose LAST comment is not from the
#                         authenticated user ("ball in court": a Copilot/human comment
#                         with no reply from us, or a re-raise after our reply, counts;
#                         a thread where WE spoke last is done from our side)
#   CopilotPending        true iff Copilot is currently in requested_reviewers (a review
#                         is in flight; wait rather than re-trigger)
#   Converged             true iff the agent has done its job:
#                         - PR state is not OPEN: always false (cannot push to it)
#                         - --single-iteration: OpenThreadsAwaitingReply == 0
#                         - a Copilot review exists or is pending:
#                           ReviewAtHead && NoNewComments && OpenThreadsAwaitingReply == 0
#                           && NOT CopilotPending. A clean review at HEAD does not end the
#                           loop while another review of the same HEAD is still in flight
#                           (a concurrent re-request, or reads straddling a submission):
#                           that review may still post findings.
#                         - no Copilot review ever observed and none pending: just
#                           OpenThreadsAwaitingReply == 0 (also true for a brand-new PR
#                           with zero threads: "nothing to do yet"; still run
#                           01-request-review.sh if Copilot is enabled)
#                         Open threads may remain: those are explicit hand-offs to the
#                         human merge owner.
#
# Parsing the JSON: output is compact, so a regex on the raw line is enough:
#   snap=$(./02-check-review-status.sh --pr 123)
#   baseline=$(printf '%s' "$snap" | grep -o '"submittedAt":"[^"]*"' | head -1 | cut -d'"' -f4)
#   case $snap in *'"CopilotPending":true'*) pending=1 ;; esac
#   case $snap in *'"Converged":true'*) converged=1 ;; esac

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' SINGLE=false
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --single-iteration) SINGLE=true; shift ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die "--pr is required."
require_int --pr "$PR"

require_tools
make_workdir
resolve_repo
resolve_me

# Big JSON lives in files under $WORK and is read with --slurpfile / stdin: passing it to
# jq as an argument can fail with "Argument list too long" on long review histories.

# The reads below are separate API calls, so something can change BETWEEN them and yield a
# snapshot that never existed: a review with body-only findings (no thread) landing after
# query A, a human replying after the threads were read, a new Copilot request after the
# requests were read. So EVERYTHING that feeds Converged is read twice (head and reviews,
# every page of threads, every page of requests) and the two passes are compared; if any
# differ, the snapshot is retried, and after 3 attempts the script fails closed instead of
# reporting a possibly stale Converged.
Q_HEAD='
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      headRefOid
      state
      reviews(last:100){nodes{author{login} state submittedAt body commit{oid}}}
    }
  }
}'
# Query A: PR head/state/reviews. reviews(last:100) is the most recent 100 reviews, enough
# to find the latest Copilot review. Writes the PR object to the file named by $1.
read_head() {
  local out
  out=$(gh_graphql_read "head query for $OWNER/$REPO PR #$PR" \
    -f query="$Q_HEAD" -f o="$OWNER" -f r="$REPO" -F n="$PR")
  printf '%s' "$out" | jq -c '.data.repository.pullRequest // empty' >"$1"
  [ -s "$1" ] || die "PR #$PR not found in $OWNER/$REPO."
}
# What must not change while we read: head commit, state, and the CONTENTS of the reviews
# (a checksum of all of it). A count plus newest timestamp is not enough: at the 100-review
# window limit a new review can displace the oldest without changing either, if two reviews
# share a timestamp, and a body-only finding in it would go unnoticed.
fingerprint() {
  jq -c '[.headRefOid, .state, .reviews.nodes]' "$1" | cksum
}

# Query B (paginated): reviewThreads. Fetch isResolved AND the last comment's author per
# thread, to compute "is this open thread awaiting our reply, or have we handed it off?".
# The loop converges when WE have nothing more to do, not when the open-thread count
# reaches zero (some threads stay open deliberately as human hand-offs). Each page's nodes
# are appended to $WORK/threads.ndjson as one JSON array per line.
Q_THREADS='
query($o:String!,$r:String!,$n:Int!,$after:String){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      reviewThreads(first:100, after:$after){
        pageInfo{endCursor hasNextPage}
        nodes{
          isResolved
          comments(last:1){nodes{author{login}}}
        }
      }
    }
  }
}'
# Query C (paginated): reviewRequests. Pagination is required for correctness so we never
# falsely report CopilotPending=false on a PR with >100 requested reviewers (which would
# make the wait step re-trigger a review that is already in flight).
Q_REQUESTS='
query($o:String!,$r:String!,$n:Int!,$after:String){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      reviewRequests(first:100, after:$after){
        pageInfo{endCursor hasNextPage}
        nodes{requestedReviewer{__typename ... on Bot{login} ... on User{login} ... on Mannequin{login}}}
      }
    }
  }
}'

# Read every page of reviewThreads into the file named by $1 (one JSON array per page per line).
read_threads() {
  local out=$1 after='' page
  : >"$out"
  while :; do
    if [ -n "$after" ]; then
      page=$(gh_graphql_read "threads query for $OWNER/$REPO PR #$PR" \
        -f query="$Q_THREADS" -f o="$OWNER" -f r="$REPO" -F n="$PR" -f after="$after")
    else
      page=$(gh_graphql_read "threads query for $OWNER/$REPO PR #$PR" \
        -f query="$Q_THREADS" -f o="$OWNER" -f r="$REPO" -F n="$PR")
    fi
    printf '%s' "$page" | jq -c '.data.repository.pullRequest.reviewThreads // empty' >"$WORK/page.json"
    [ -s "$WORK/page.json" ] || die "PR #$PR not found in $OWNER/$REPO (threads page)."
    jq -c '.nodes' "$WORK/page.json" >>"$out"
    [ "$(jq -r '.pageInfo.hasNextPage' "$WORK/page.json")" = true ] || break
    after=$(jq -r '.pageInfo.endCursor' "$WORK/page.json")
  done
}

# Same for reviewRequests.
read_requests() {
  local out=$1 after='' page
  : >"$out"
  while :; do
    if [ -n "$after" ]; then
      page=$(gh_graphql_read "reviewRequests query for $OWNER/$REPO PR #$PR" \
        -f query="$Q_REQUESTS" -f o="$OWNER" -f r="$REPO" -F n="$PR" -f after="$after")
    else
      page=$(gh_graphql_read "reviewRequests query for $OWNER/$REPO PR #$PR" \
        -f query="$Q_REQUESTS" -f o="$OWNER" -f r="$REPO" -F n="$PR")
    fi
    printf '%s' "$page" | jq -c '.data.repository.pullRequest.reviewRequests // empty' >"$WORK/page.json"
    [ -s "$WORK/page.json" ] || die "PR #$PR not found in $OWNER/$REPO (reviewRequests page)."
    jq -c '.nodes' "$WORK/page.json" >>"$out"
    [ "$(jq -r '.pageInfo.hasNextPage' "$WORK/page.json")" = true ] || break
    after=$(jq -r '.pageInfo.endCursor' "$WORK/page.json")
  done
}

ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))

  # Pass 1: this is the data the verdict is computed from.
  read_head "$WORK/pr.json"
  read_threads "$WORK/threads.ndjson"
  read_requests "$WORK/requests.ndjson"

  # Pass 2: read everything again and compare. Equal means nothing moved while we read.
  read_head "$WORK/pr_after.json"
  read_threads "$WORK/threads_after.ndjson"
  read_requests "$WORK/requests_after.ndjson"
  if [ "$(fingerprint "$WORK/pr.json")" = "$(fingerprint "$WORK/pr_after.json")" ] &&
    [ "$(cksum <"$WORK/threads.ndjson")" = "$(cksum <"$WORK/threads_after.ndjson")" ] &&
    [ "$(cksum <"$WORK/requests.ndjson")" = "$(cksum <"$WORK/requests_after.ndjson")" ]; then
    break
  fi
  [ "$ATTEMPT" -lt 3 ] ||
    die "PR #$PR changed (a new commit, review, reply, or review request landed) while it was being read, on 3 consecutive attempts, so a consistent snapshot could not be taken. Refusing to report a possibly stale result; re-run in a moment."
done

# reviews(last:100) is the MOST RECENT 100 reviews. If a PR has 100+ reviews more recent
# than the last Copilot review (essentially impossible in normal use), the latest Copilot
# review would be cut off. Warn on stderr when we hit the boundary.
if [ "$(jq '.reviews.nodes | length' "$WORK/pr.json")" -ge 100 ]; then
  warn "reviews(last:100) boundary hit on PR #$PR; if there are 100+ non-Copilot reviews more recent than the latest Copilot review, LatestCopilotReview may be stale. Inspect via 'gh pr view $PR --comments' if convergence behaves unexpectedly."
fi

# Latest Copilot review: prefer the newest one whose commit matches HEAD, otherwise the
# newest overall.
jq -cn \
  --slurpfile prs "$WORK/pr.json" \
  --slurpfile thread_pages "$WORK/threads.ndjson" \
  --slurpfile request_pages "$WORK/requests.ndjson" \
  --arg me "$ME" --arg rx "$COPILOT_LOGIN_REGEX" --argjson single "$SINGLE" \
  --argjson n "$PR" --arg o "$OWNER" --arg r "$REPO" \
  "$JQ_REVIEW_LIB"'
  $prs[0] as $pr
  | ($thread_pages | add // []) as $threads
  | ($request_pages | add // []) as $requests
  | [$pr.reviews.nodes[] | select(.author and .author.login and (.author.login | test($rx; "i")))] as $cr
  | (if ($cr | length) == 0 then null
     else (([$cr[] | select(.commit and .commit.oid == $pr.headRefOid)] | sort_by(.submittedAt) | reverse | .[0])
           // ($cr | sort_by(.submittedAt) | reverse | .[0]))
     end) as $latest
  | (($latest.body // "")) as $body
  | ($latest != null and ($latest.commit.oid // null) == $pr.headRefOid) as $atHead
  | ($body | review_clean) as $clean
  | ($body | previously_missed_count) as $missed
  | [$threads[] | select(.isResolved | not)] as $open
  | ([$open[] | select((.comments.nodes | last | .author.login? // null) != $me)] | length) as $awaiting
  | ([$requests[] | select(.requestedReviewer and .requestedReviewer.login and (.requestedReviewer.login | test($rx; "i")))] | length > 0) as $pending
  | {
      PrNumber: $n, Owner: $o, Repo: $r,
      HeadOid: $pr.headRefOid, State: $pr.state,
      LatestCopilotReview: (if $latest then {
          state: $latest.state, submittedAt: $latest.submittedAt,
          commitOid: ($latest.commit.oid // null), bodyHead: $body[0:300]
        } else null end),
      ReviewAtHead: $atHead,
      NoNewComments: $clean,
      PreviouslyMissedCount: $missed,
      ReviewVerdict: (if $latest then ($body | review_heading) else null end),
      ReviewSummary: (if $latest then ($body | review_summary) else null end),
      OpenThreadCount: ($open | length),
      OpenThreadsAwaitingReply: $awaiting,
      CopilotPending: $pending,
      Converged: (
        if $pr.state != "OPEN" then false
        elif $single then $awaiting == 0
        elif ($latest != null or $pending) then ($atHead and $clean and $awaiting == 0 and ($pending | not))
        else $awaiting == 0 end)
    }'
