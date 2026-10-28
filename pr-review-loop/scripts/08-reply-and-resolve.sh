#!/usr/bin/env bash
# Post a reply on a review thread and (by default) resolve it.
#
# Performs the two GraphQL mutations needed to address a finding:
#   1. addPullRequestReviewThreadReply: appends a reply comment.
#   2. resolveReviewThread:             marks the thread resolved.
# Use it for accepted-and-fixed findings and for declined-with-rationale findings. See
# ../templates/reply-fix.md, reply-decline.md, reply-drift.md, and reply-partial.md for
# body patterns.
#
# Usage:
#   08-reply-and-resolve.sh --thread-id <PRRT_...> --body <text> [--no-resolve]
#
#   --thread-id   The GraphQL node ID of the review thread (e.g. PRRT_kw...).
#   --body        The reply body. Markdown is supported. Passed to GraphQL as a plain
#                 string (`gh -f`, never `-F`, so a body that looks like `true`, `null`,
#                 a number, or `@file` is never coerced or read from disk).
#   --no-resolve  Post the reply only and leave the thread open (use for escalated
#                 threads, or to start a back-and-forth). An invisible hand-off marker
#                 is appended to the body so 10-cleanup-outdated.sh never auto-resolves
#                 the thread later, even once it goes outdated and even with --force.
#
# Prints "Replied to thread <id>" and then, unless --no-resolve, "Resolved thread <id>".
#
# Safe to re-run after ANY failure. Reply and resolve are two mutations and a lost response
# can leave a reply posted even though this script reported an error, so before posting it
# reads the thread: if the thread's last comment is already this exact reply from you, it
# skips the reply (printing "Reply already on thread <id>") and carries on to resolve. If
# that read itself fails, it stops rather than risk a duplicate. Retry policy:
#   - Just re-run the same command.
#   - Mutations are never auto-retried inside the script, and the duplicate check only
#     looks at the LAST comment, so a different reply posted in between is not matched.
#   - To resolve without replying: gh api graphql \
#       -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}' \
#       -f t=<thread-id>

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

THREAD_ID='' BODY='' HAVE_BODY=false RESOLVE=true
while [ $# -gt 0 ]; do
  case $1 in
    --thread-id) need_value $# --thread-id; THREAD_ID=$2; shift 2 ;;
    --body) need_value $# --body; BODY=$2; HAVE_BODY=true; shift 2 ;;
    --no-resolve) RESOLVE=false; shift ;;
    -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$THREAD_ID" ] || die "--thread-id is required."
{ [ "$HAVE_BODY" = true ] && [ -n "$BODY" ]; } || die "--body is required (and must be non-empty)."

require_tools
resolve_me

# A reply that leaves the thread open is a deliberate hand-off to a human: mark it.
if [ "$RESOLVE" = false ]; then
  BODY="$BODY

$HANDOFF_MARKER"
fi

REPLY_MUTATION='
mutation($tid: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: $tid,
    body: $body
  }) {
    comment { id }
  }
}'
# Idempotency: skip the reply if the thread's last comment is already exactly this reply
# from us (an earlier run whose response was lost). Trailing whitespace is ignored because
# GitHub may normalize it. A failed read stops the script (no guessing).
LAST_QUERY='
query($tid: ID!) {
  node(id: $tid) {
    ... on PullRequestReviewThread {
      comments(last: 1) { nodes { author { login } body } }
    }
  }
}'
last=$(gh_graphql_read "read thread $THREAD_ID before replying" -f query="$LAST_QUERY" -f tid="$THREAD_ID")
ALREADY=$(printf '%s' "$last" | jq -r --arg me "$ME" --arg body "$BODY" '
  (.data.node.comments.nodes[0] // null) as $c
  | if $c != null and ($c.author.login // "") == $me
       and (($c.body // "") | sub("\\s+$"; "")) == ($body | sub("\\s+$"; ""))
    then "yes" else "no" end')
if [ "$ALREADY" = yes ]; then
  echo "Reply already on thread $THREAD_ID (not posting a duplicate)"
else
  gh_graphql "reply to thread $THREAD_ID" \
    -f query="$REPLY_MUTATION" -f tid="$THREAD_ID" -f body="$BODY" >/dev/null
  echo "Replied to thread $THREAD_ID"
fi

if [ "$RESOLVE" = true ]; then
  RESOLVE_MUTATION='
mutation($tid: ID!) {
  resolveReviewThread(input: { threadId: $tid }) {
    thread { isResolved }
  }
}'
  gh_graphql "resolve thread $THREAD_ID" \
    -f query="$RESOLVE_MUTATION" -f tid="$THREAD_ID" >/dev/null
  echo "Resolved thread $THREAD_ID"
fi
