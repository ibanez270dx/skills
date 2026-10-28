#!/usr/bin/env bash
# Batch-resolve outdated Copilot review threads on a PR.
#
# After a review loop converges, the PR may still show old `isOutdated` Copilot threads
# as open: addressed by later commits but never explicitly resolved. This finds and
# resolves them in bulk. Safety net only: most loops converge with nothing to clean.
#
# Only acts on threads where ALL of these hold:
#   - isOutdated: true, and isResolved: false
#   - the first comment's author is copilot-pull-request-reviewer
#   - the LAST comment's author is the authenticated user (we already replied). This
#     stops it from hiding an actionable finding if invoked before the loop converged.
#     Override with --force.
#   - NO comment in the thread is from a non-Copilot, non-authenticated-user author (the
#     "human-in-thread" guard: if a human or another bot chimed in ANYWHERE in the
#     thread, even after Copilot's opener, the thread is skipped). NOT overridable by
#     --force: auto-resolving a thread carrying human signal would silently hide
#     unaddressed concerns.
#   - the thread is not a hand-off: if the LAST comment is ours and carries the hand-off
#     marker (08-reply-and-resolve.sh adds it to every --no-resolve reply), a human was
#     deliberately asked to look at it, so cleanup leaves it open. NOT overridable by
#     --force. Without this, an escalated thread that later goes outdated would be
#     silently resolved, defeating the hand-off.
#   - every commenter's identity is known. A ghost/deleted user (null author) makes
#     authorship unknowable, so the thread is skipped (fail-safe), also regardless of
#     --force.
# So "threads from human reviewers are never touched" holds for single-author human
# threads AND for mixed threads where Copilot opened and a human replied.
#
# Usage:
#   10-cleanup-outdated.sh --pr <n> [--owner <o> --repo <r>] [--dry-run] [--force]
#
#   --pr <n>        The pull request number (required).
#   --owner/--repo  Optional; both or neither. Default: the current directory's repo.
#   --dry-run       Print what would be resolved without making any mutation.
#   --force         Skip only the "last commenter must be us" guard (see above).
#
# Exits 1 if any resolve mutation failed (after trying every thread).

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PR='' OWNER='' REPO='' DRY_RUN=false FORCE=false
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; PR=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
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

QUERY='
query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { endCursor hasNextPage }
        nodes {
          id
          isResolved
          isOutdated
          firstComment: comments(first: 1) { nodes { author { login } } }
          lastComment: comments(last: 1) { nodes { author { login } body } }
          # First page of comment authors, so we can reject threads where any non-Copilot,
          # non-me participant commented. totalCount is kept for diagnostics; hasNextPage
          # is the signal that more pages exist (fetched via the node(id:) query below).
          allComments: comments(first: 100) {
            totalCount
            pageInfo { endCursor hasNextPage }
            nodes { author { login } }
          }
        }
      }
    }
  }
}'

# Each page's nodes go to $WORK/threads.ndjson (one JSON array per line): a long thread list
# passed to jq as an argument can exceed argument limits.
: >"$WORK/threads.ndjson"
AFTER=''
while :; do
  if [ -n "$AFTER" ]; then
    data=$(gh_graphql_read "list outdated threads for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" -f after="$AFTER")
  else
    data=$(gh_graphql_read "list outdated threads for $OWNER/$REPO PR #$PR" \
      -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR")
  fi
  printf '%s' "$data" | jq -c '.data.repository.pullRequest.reviewThreads // empty' >"$WORK/page.json"
  [ -s "$WORK/page.json" ] || die "PR #$PR not found in $OWNER/$REPO."
  jq -c '.nodes' "$WORK/page.json" >>"$WORK/threads.ndjson"
  [ "$(jq -r '.pageInfo.hasNextPage' "$WORK/page.json")" = true ] || break
  AFTER=$(jq -r '.pageInfo.endCursor' "$WORK/page.json")
done

# When a thread has more than 100 comments, fetch the rest of their authors via
# node(id:) so authorship visibility is always complete. Prints a JSON array of author
# logins in order, with null for ghost/deleted users. Dies (so the caller can skip the
# thread, fail-safe) if the server misbehaves: a null node, a missing comments
# connection, a cursor that stops advancing, or more than MAX_PAGES pages.
MAX_PAGES=200
all_thread_authors() {
  local thread_json=$1 tid authors has_next after prev page_index=0 resp conn
  local qpage='
query($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $after) {
        pageInfo { endCursor hasNextPage }
        nodes { author { login } }
      }
    }
  }
}'
  tid=$(printf '%s' "$thread_json" | jq -r '.id')
  authors=$(printf '%s' "$thread_json" | jq -c '[.allComments.nodes[]? | (.author.login? // null)]')
  has_next=$(printf '%s' "$thread_json" | jq -r '.allComments.pageInfo.hasNextPage // false')
  after=$(printf '%s' "$thread_json" | jq -r '.allComments.pageInfo.endCursor // ""')
  while [ "$has_next" = true ]; do
    page_index=$((page_index + 1))
    [ "$page_index" -le "$MAX_PAGES" ] ||
      die "exceeded MAX_PAGES=$MAX_PAGES for thread $tid; likely a malformed server response (cursor not advancing)."
    if [ -n "$after" ]; then
      resp=$(gh_graphql_read "paginate comments for thread $tid (page $page_index)" \
        -f query="$qpage" -f id="$tid" -f after="$after")
    else
      resp=$(gh_graphql_read "paginate comments for thread $tid (page $page_index)" \
        -f query="$qpage" -f id="$tid")
    fi
    conn=$(printf '%s' "$resp" | jq -c '.data.node.comments // empty')
    [ -n "$conn" ] || die "node(id: '$tid') returned no comments connection on page $page_index (thread deleted or inaccessible)."
    # The accumulator can grow large on a long thread, so it goes in on stdin; only the
    # (at most 100) authors from this page are passed as an argument.
    authors=$(printf '%s' "$authors" | jq -c \
      --argjson add "$(printf '%s' "$conn" | jq -c '[.nodes[]? | (.author.login? // null)]')" '. + $add')
    prev=$after
    has_next=$(printf '%s' "$conn" | jq -r '.pageInfo.hasNextPage // false')
    after=$(printf '%s' "$conn" | jq -r '.pageInfo.endCursor // ""')
    if [ "$has_next" = true ] && [ "$after" = "$prev" ]; then
      die "pagination cursor did not advance for thread $tid on page $page_index (server returned the same endCursor='$after')."
    fi
  done
  printf '%s\n' "$authors"
}

SKIPPED_AWAITING=0 SKIPPED_HUMAN=0 SKIPPED_UNKNOWN=0 SKIPPED_PAGINATION=0 SKIPPED_HANDOFF=0
TARGETS=''  # newline-separated thread ids
PAGE_ERR=$(mktemp "${TMPDIR:-/tmp}/pr-review-loop.XXXXXX")

# Candidates: outdated, unresolved, opened by Copilot. One JSON object per line.
CANDIDATES=$(jq -c --arg rx "$COPILOT_LOGIN_REGEX" '
  .[]
  | select(.isOutdated and (.isResolved | not))
  | select((.firstComment.nodes[0].author.login? // "") | test($rx; "i"))' "$WORK/threads.ndjson")

while IFS= read -r thread; do
  [ -n "$thread" ] || continue
  tid=$(printf '%s' "$thread" | jq -r '.id')

  # Per-thread isolation: a pagination failure on ONE thread must not abort the rest of
  # the pass. On failure, SKIP the thread (never resolve when authorship is unknown).
  if ! authors=$(all_thread_authors "$thread" 2>"$PAGE_ERR"); then
    SKIPPED_PAGINATION=$((SKIPPED_PAGINATION + 1))
    warn "Pagination failed for thread $tid; skipping (fail-safe): $(cat "$PAGE_ERR" 2>/dev/null)"
    continue
  fi

  # human: any commenter who isn't us or Copilot (wins over unknown).
  # unknown: a null (ghost/deleted) author, so we can't tell who touched the thread.
  verdict=$(printf '%s' "$authors" | jq -r --arg me "$ME" --arg rx "$COPILOT_LOGIN_REGEX" '
    if any(.[]; . != null and . != $me and ((test($rx; "i")) | not)) then "human"
    elif any(.[]; . == null) then "unknown"
    else "ok" end')
  case $verdict in
    human) SKIPPED_HUMAN=$((SKIPPED_HUMAN + 1)); continue ;;
    unknown) SKIPPED_UNKNOWN=$((SKIPPED_UNKNOWN + 1)); continue ;;
  esac

  last=$(printf '%s' "$thread" | jq -r '.lastComment.nodes[0].author.login? // ""')

  # Hand-off guard: our own last comment carries the marker, so a human was deliberately
  # asked to look at this thread. Leave it open. Not overridable by --force.
  if [ "$last" = "$ME" ] &&
    printf '%s' "$thread" | jq -e --arg m "$HANDOFF_MARKER" '(.lastComment.nodes[0].body // "") | contains($m)' >/dev/null; then
    SKIPPED_HANDOFF=$((SKIPPED_HANDOFF + 1))
    continue
  fi

  # Don't resolve threads where anyone other than us had the last word: we haven't
  # replied yet, so resolving would hide an actionable finding.
  if [ "$FORCE" != true ] && [ "$last" != "$ME" ]; then
    SKIPPED_AWAITING=$((SKIPPED_AWAITING + 1))
    continue
  fi

  TARGETS="${TARGETS}${tid}
"
done <<EOF
$CANDIDATES
EOF
rm -f "$PAGE_ERR"

if [ "$SKIPPED_HUMAN" -gt 0 ]; then
  echo "Skipped $SKIPPED_HUMAN outdated Copilot thread(s) where a non-Copilot, non-'$ME' commenter participated (--force does NOT override this: human signal must not silently disappear)."
fi
if [ "$SKIPPED_UNKNOWN" -gt 0 ]; then
  echo "Skipped $SKIPPED_UNKNOWN outdated Copilot thread(s) with at least one ghost / deleted-user (null author) comment (--force does NOT override this: authorship is unknown, fail-safe is to skip)."
fi
if [ "$SKIPPED_HANDOFF" -gt 0 ]; then
  echo "Skipped $SKIPPED_HANDOFF outdated Copilot thread(s) left open as a hand-off to a human (their last comment carries the hand-off marker; --force does NOT override this)."
fi
if [ "$SKIPPED_AWAITING" -gt 0 ]; then
  echo "Skipped $SKIPPED_AWAITING outdated Copilot thread(s) where the last comment is not from '$ME' (pass --force to override)."
fi
if [ "$SKIPPED_PAGINATION" -gt 0 ]; then
  echo "Skipped $SKIPPED_PAGINATION outdated Copilot thread(s) due to authorship-pagination errors (fail-safe: never resolve when authorship is unknown). See warnings above for per-thread detail."
fi

TARGET_COUNT=$(printf '%s' "$TARGETS" | grep -c . || true)
if [ "$TARGET_COUNT" -eq 0 ]; then
  echo 'No outdated Copilot threads to clean up.'
  exit 0
fi
echo "Found $TARGET_COUNT outdated Copilot thread(s) to resolve."

RESOLVE_MUTATION='
mutation($tid: ID!) {
  resolveReviewThread(input: { threadId: $tid }) {
    thread { isResolved }
  }
}'

# Per-thread isolation again: a single mutation failure (rate limit, transient error,
# thread vanished mid-loop) must not leave the remaining threads unresolved. Track
# successes and failures, summarise, and exit non-zero if any failed.
RESOLVED=0 FAILED_COUNT=0 FAILED_LIST=''
while IFS= read -r tid; do
  [ -n "$tid" ] || continue
  if [ "$DRY_RUN" = true ]; then
    echo "Would resolve $tid (DryRun)"
    continue
  fi
  if err=$(gh_graphql "resolve outdated thread $tid" -f query="$RESOLVE_MUTATION" -f tid="$tid" 2>&1 >/dev/null); then
    echo "Resolved $tid"
    RESOLVED=$((RESOLVED + 1))
  else
    warn "Failed to resolve $tid: $err"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_LIST="${FAILED_LIST:+$FAILED_LIST; }$tid ($err)"
  fi
done <<EOF
$TARGETS
EOF

if [ "$DRY_RUN" != true ]; then
  echo "Cleanup summary: resolved=$RESOLVED failed=$FAILED_COUNT skippedAwaitingReply=$SKIPPED_AWAITING skippedHumanInThread=$SKIPPED_HUMAN skippedUnknownAuthorInThread=$SKIPPED_UNKNOWN skippedPaginationError=$SKIPPED_PAGINATION skippedHandoff=$SKIPPED_HANDOFF"
  if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "Failed threads: $FAILED_LIST"
    exit 1
  fi
fi
