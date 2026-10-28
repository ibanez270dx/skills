#!/usr/bin/env bash
# Print the latest Copilot review of a PR, body included (read-only).
#
# Why this exists: Copilot can list real findings in the review BODY (under "Previously
# missed (N)") with no review thread, so 03-list-open-threads.sh can't see them.
# 02-check-review-status.sh reports their count (PreviouslyMissedCount); this prints the
# review they are in. Don't fetch it with `gh api repos/.../pulls/<n>/reviews`: REST
# returns only the first page (30 reviews) OLDEST first, so on a long loop it omits the
# newest review, which is exactly the one you need.
#
# The review is chosen exactly as 02-check-review-status.sh chooses LatestCopilotReview:
# the newest Copilot review whose commit is the PR's HEAD, else the newest overall, from
# the most recent 100 reviews. So the body you read always matches the status snapshot.
#
# Usage:
#   03-review-body.sh --pr <n> [--owner <o> --repo <r>] [--raw]
#
#   --pr <n>        The pull request number (required).
#   --owner/--repo  Optional; both or neither. Default: the current directory's repo.
#   --raw           Print only the review body (markdown), nothing else.
#
# Output (default, one line of compact JSON):
#   {"PrNumber","Owner","Repo","HeadOid","Found","ReviewAtHead","State","SubmittedAt",
#    "CommitOid","Url","PreviouslyMissedCount","ReviewVerdict","ReviewSummary","Body"}
# Found is false (and the review fields are null) when there is no Copilot review.
#
# Handle each "Previously missed" finding like a thread: triage it (step 4), fix it in the
# round's commit, and since there is no thread to resolve, reply with ONE PR comment that
# cites the pushed SHA:  gh pr comment <n> --body "..."

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' RAW=false
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --raw) RAW=true; shift ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die "--pr is required."
require_int --pr "$PR"

require_tools
make_workdir
resolve_repo

QUERY='
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    pullRequest(number:$n){
      headRefOid
      reviews(last:100){nodes{author{login} state submittedAt body url commit{oid}}}
    }
  }
}'
data=$(gh_graphql_read "latest review for $OWNER/$REPO PR #$PR" \
  -f query="$QUERY" -f o="$OWNER" -f r="$REPO" -F n="$PR")
printf '%s' "$data" | jq -c '.data.repository.pullRequest // empty' >"$WORK/pr.json"
[ -s "$WORK/pr.json" ] || die "PR #$PR not found in $OWNER/$REPO."

# The selected review, as one JSON object (or null), via the same rule as 02.
jq -c --arg rx "$COPILOT_LOGIN_REGEX" --argjson pr_head "$(jq '.headRefOid' "$WORK/pr.json")" '
  [.reviews.nodes[] | select(.author and .author.login and (.author.login | test($rx; "i")))] as $cr
  | if ($cr | length) == 0 then null
    else (([$cr[] | select(.commit and .commit.oid == $pr_head)] | sort_by(.submittedAt) | reverse | .[0])
          // ($cr | sort_by(.submittedAt) | reverse | .[0]))
    end' "$WORK/pr.json" >"$WORK/review.json"

if [ "$RAW" = true ]; then
  jq -r '(. // {}) | .body // ""' "$WORK/review.json"
  exit 0
fi

jq -cn --slurpfile prs "$WORK/pr.json" --slurpfile revs "$WORK/review.json" \
  --argjson n "$PR" --arg o "$OWNER" --arg r "$REPO" \
  "$JQ_REVIEW_LIB"'
  $prs[0] as $pr | $revs[0] as $rv
  | ($rv.body // "") as $body
  | {
      PrNumber: $n, Owner: $o, Repo: $r, HeadOid: $pr.headRefOid,
      Found: ($rv != null),
      ReviewAtHead: ($rv != null and ($rv.commit.oid // null) == $pr.headRefOid),
      State: ($rv.state // null),
      SubmittedAt: ($rv.submittedAt // null),
      CommitOid: ($rv.commit.oid // null),
      Url: ($rv.url // null),
      PreviouslyMissedCount: ($body | previously_missed_count),
      ReviewVerdict: (if $rv then ($body | review_heading) else null end),
      ReviewSummary: (if $rv then ($body | review_summary) else null end),
      Body: (if $rv then $body else null end)
    }'
