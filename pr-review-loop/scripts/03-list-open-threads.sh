#!/usr/bin/env bash
# List unresolved review threads on a pull request, from ALL reviewers (Copilot, humans,
# other bots), with enough of each conversation to triage it. The triage step decides what
# to do with each.
#
# Each thread carries its opener (Author/Path/Body, where path and line come from) AND the
# replies after it, because the opener alone hides what matters for the decision: a human
# who challenged a Copilot finding, or the rationale of an earlier decline. 02 counts a
# human's last comment as "awaiting our reply", so 03 must show that comment too.
#
# Usage:
#   03-list-open-threads.sh --pr <n> [--owner <o> --repo <r>] [--max-body-length <n>]
#
#   --pr <n>               The pull request number (required).
#   --owner/--repo         Optional; both or neither. Default: the current directory's
#                          repo, via `gh repo view`.
#   --max-body-length <n>  Cap each comment Body at this many characters (default 500; 0
#                          disables). Long comments otherwise dominate stdout; truncated
#                          bodies end with "…". Newlines in a body become spaces.
#
# Output (one line of compact JSON):
#   {"PrNumber","Owner","Repo","OpenThreadCount","Threads":[{
#      "ThreadId","Author","Path","CreatedAt","Body",      the opener (Author is its author)
#      "CommentCount","Truncated",                         Truncated: more than 100 comments
#      "LastAuthor","AwaitingReply",                       AwaitingReply: last author is not us
#      "HumanParticipated",                                see below
#      "Replies":[{"Author","CreatedAt","Body"}, ...]      the comments after the opener
#   }, ...]}
# Path is "<file>:<line>" when the opener is anchored to a line, else just "<file>".
# HumanParticipated is true when ANY comment (the opener included) is from someone who is
# neither Copilot nor the authenticated user, or from a deleted account (unknown, so
# treated as human). Such a thread is never loop-owned: escalate it (step 4), even when
# Copilot opened it.
#
# Only the first 100 comments are fetched. LastAuthor and AwaitingReply always come from
# the thread's real last comment (read separately), but when Truncated is true the unseen
# middle may hold a human, so HumanParticipated is forced to true (escalate) rather than
# guessed from the visible part, and Replies is only the visible part. A thread that long
# is not a routine finding anyway.
#
# NOTE: this lists review THREADS only. Copilot can also list findings in the review
# body under "Previously missed (N)"; those have no thread. See PreviouslyMissedCount
# in 02-check-review-status.sh and 03-review-body.sh.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' MAX_BODY=500
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --max-body-length) need_value $# --max-body-length; MAX_BODY=$2; shift 2 ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$PR" ] || die "--pr is required."
require_int --pr "$PR"
case $MAX_BODY in '' | *[!0-9]*) die "--max-body-length must be a non-negative integer (got '$MAX_BODY')." ;; esac

require_tools
make_workdir
resolve_repo
resolve_me

QUERY='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { endCursor hasNextPage }
        nodes {
          id
          isResolved
          comments(first: 100) {
            totalCount
            nodes { author { login } body path line createdAt }
          }
          lastComment: comments(last: 1) { nodes { author { login } } }
        }
      }
    }
  }
}'

# Each page's nodes go to $WORK/threads.ndjson (one JSON array per line) and are read back
# with --slurpfile: a long thread list passed to jq as an argument can exceed argument limits.
: >"$WORK/threads.ndjson"
AFTER=''
while :; do
  if [ -n "$AFTER" ]; then
    data=$(gh_graphql_read "list threads for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" -f after="$AFTER")
  else
    data=$(gh_graphql_read "list threads for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR")
  fi
  printf '%s' "$data" | jq -c '.data.repository.pullRequest.reviewThreads // empty' >"$WORK/page.json"
  [ -s "$WORK/page.json" ] || die "PR #$PR not found in $OWNER/$REPO."
  jq -c '.nodes' "$WORK/page.json" >>"$WORK/threads.ndjson"
  [ "$(jq -r '.pageInfo.hasNextPage' "$WORK/page.json")" = true ] || break
  AFTER=$(jq -r '.pageInfo.endCursor' "$WORK/page.json")
done

jq -cn --slurpfile pages "$WORK/threads.ndjson" --argjson max "$MAX_BODY" \
  --arg me "$ME" --arg rx "$COPILOT_LOGIN_REGEX" \
  --argjson n "$PR" --arg o "$OWNER" --arg r "$REPO" '
  def flat: ((. // "") | gsub("\r?\n"; " ")) | if $max > 0 and length > $max then (.[0:$max] + "…") else . end;
  def login: (.author.login // null);
  ($pages | add // []) as $threads
  | [ $threads[]
    | select(.isResolved | not)
    # A malformed thread (no originating comment) is skipped rather than crashing.
    | select((.comments.nodes | length) > 0)
    | . as $t
    | .comments.nodes as $cs
    | $cs[0] as $c
    # The real last comment, not the last of the (possibly truncated) first 100. Fall back to
    # the visible last comment only when the last-comment node is absent; a PRESENT node whose
    # author is null is a deleted account and stays unknown (null), never replaced by the
    # name of a different commenter.
    | (($t.lastComment.nodes // []) as $ln
       | if ($ln | length) > 0 then ($ln | last | login) else ($cs | last | login) end) as $last
    | (($t.comments.totalCount // ($cs | length)) > ($cs | length)) as $truncated
    | {
        ThreadId: $t.id,
        Author: ($c | login // "(deleted)"),
        Path: (if $c.line != null then "\($c.path):\($c.line)" else $c.path end),
        CreatedAt: ($c.createdAt // ""),
        Body: ($c.body | flat),
        CommentCount: ($t.comments.totalCount // ($cs | length)),
        Truncated: $truncated,
        LastAuthor: ($last // "(deleted)"),
        AwaitingReply: ($last != $me),
        # Anyone who is not Copilot or us, or an unknown (deleted) account, counts as a human.
        HumanParticipated: ($truncated or ([$cs[] | login] | any(. == null or (. != $me and ((test($rx; "i")) | not))))),
        Replies: [$cs[1:][] | { Author: (login // "(deleted)"), CreatedAt: (.createdAt // ""), Body: (.body | flat) }]
      }
  ] as $out
  | { PrNumber: $n, Owner: $o, Repo: $r, OpenThreadCount: ($out | length), Threads: $out }'
