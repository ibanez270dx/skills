#!/usr/bin/env bash
# Step 0: verify the checkout is safe to work in BEFORE touching the repo, and print the
# verified push target. Run it once at the start of the loop, before step 5 (fix) and again
# before step 7 (commit + push) if the checkout may have changed.
#
# The other scripts talk to the GitHub API about whichever PR `--pr` names, regardless of
# what is checked out. Step 7 then runs plain `git commit` / `git push`, so without this
# check, running from the right repo on `main` (or on another PR's branch) would publish
# fixes to the wrong branch, and a fork PR needs the HEAD repository's remote, not origin.
#
# It verifies and reports:
#   - the PR is OPEN, and which branch/repo is its head
#   - the checked-out branch IS the PR's head branch (else: `gh pr checkout <n>`)
#   - the head branch is not the default or a shared branch (main, master, ...)
#   - a local remote actually points at the HEAD repo (fork-aware; compares host/owner/repo
#     and every configured pushurl)
#   - the local branch is not behind the remote (pushing/amending would clobber commits)
#   - whether HEAD is yours / a merge commit, i.e. whether amending is safe
# and prints the exact, shell-escaped command to push with ("Push command"). Step 7 must
# push with THAT command, never a bare `git push`.
#
# Usage:
#   00-preflight.sh --pr <number|url|branch> [--owner <o> --repo <r>]
#   00-preflight.sh <number|url|branch>              (positional form)
#
#   --pr <ref>      The PR to check. With a bare number the repo comes from the current
#                   directory's git remote (or --owner/--repo).
#   --owner/--repo  Optional; both or neither. Look the PR up in that repo.
#
# Exit 0 = safe to proceed. Exit 1 = hard stop: read the STOP lines and fix them first.
# WARN lines are advisory.
set -uo pipefail

# Never hang the loop. git over https can sit at a credential prompt forever, and a stalled
# network call has no timeout by default: turn prompts off, make ssh non-interactive, and
# abort fetches that stall (below 1 KB/s for 20 s). A failed fetch only produces a WARN.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
GIT_FETCH="git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

need_value() { [ "$1" -ge 2 ] || { echo "$2 requires a value." >&2; exit 1; }; }

REF=""
OWNER_ARG=""
REPO_ARG=""
while [ $# -gt 0 ]; do
  case $1 in
    --pr) need_value $# --pr; REF=$2; shift 2 ;;
    --owner) need_value $# --owner; OWNER_ARG=$2; shift 2 ;;
    --repo) need_value $# --repo; REPO_ARG=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
    *) REF=$1; shift ;;
  esac
done
if { [ -n "$OWNER_ARG" ] && [ -z "$REPO_ARG" ]; } || { [ -z "$OWNER_ARG" ] && [ -n "$REPO_ARG" ]; }; then
  echo "pass both --owner and --repo, or neither" >&2
  exit 1
fi
REPO_FLAG=""
[ -z "$OWNER_ARG" ] || REPO_FLAG="--repo $OWNER_ARG/$REPO_ARG"

STOPS=""
WARNS=""
stop() { STOPS="$STOPS
  STOP: $1"; }
warn() { WARNS="$WARNS
  WARN: $1"; }

command -v jq >/dev/null 2>&1 || { echo "STOP: jq is required (brew install jq)" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "STOP: not inside a git work tree -- cd into a clone of the PR's repo first" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel)
FIELDS=number,url,state,isDraft,headRefName,headRefOid,baseRefName,headRepository,headRepositoryOwner,mergeStateStatus
if [ -n "$REF" ]; then
  PR=$(gh pr view "$REF" $REPO_FLAG --json "$FIELDS") || exit 1
else
  PR=$(gh pr view $REPO_FLAG --json "$FIELDS") || exit 1
fi
val() { printf '%s' "$PR" | jq -r "$1"; }

NUMBER=$(val .number)
PR_URL=$(val .url)
STATE=$(val .state)
DRAFT=$(val .isDraft)
HEAD_BRANCH=$(val .headRefName)
HEAD_OID=$(val .headRefOid)
BASE_BRANCH=$(val .baseRefName)
HEAD_OWNER=$(val '.headRepositoryOwner.login // ""')
HEAD_REPO=$(val '.headRepository.name // ""')
MERGE_STATE=$(val '.mergeStateStatus // ""')

BASE_OWNER=$(printf '%s' "$PR_URL" | sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*$#\1#')
BASE_REPO=$(printf  '%s' "$PR_URL" | sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*$#\2#')
PR_HOST=$(printf '%s' "$PR_URL" | sed -E 's#^https?://([^/]+)/.*$#\1#')
if ! DEFAULT_BRANCH=$(gh repo view "$HEAD_OWNER/$HEAD_REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null); then
  DEFAULT_BRANCH=""
  stop "could not determine default branch for $HEAD_OWNER/$HEAD_REPO (gh repo view failed) -- cannot verify head branch isn't the default branch"
fi

IS_FORK=false
[ "$HEAD_OWNER/$HEAD_REPO" = "$BASE_OWNER/$BASE_REPO" ] || IS_FORK=true

# Which local remote points at which repo? Compares the full host/owner/repo
# so a same-path remote on a different host (e.g. an Enterprise mirror) can't
# false-match, and --push resolves against pushurl (what `git push` actually
# uses) rather than the fetch URL, since those can diverge. A remote can have
# more than one configured pushurl (git pushes to all of them), so --push
# uses --all and requires every one to match -- checking only the first would
# certify a remote as safe even when a second pushurl points elsewhere.
remote_for() { # remote_for <owner>/<repo> [--push]
  local push_flag=""
  [ "${2:-}" = "--push" ] && push_flag="--push --all"
  for r in $(git remote); do
    urls=$(git remote get-url $push_flag "$r" 2>/dev/null) || continue
    [ -n "$urls" ] || continue
    all_match=true
    while IFS= read -r url; do
      norm=$(printf '%s' "$url" | sed -E -e 's#\.git$##' -e 's#^git@([^:]+):#\1/#' -e 's#^[a-z]+://([^/@]*@)?##')
      [ "$norm" = "$PR_HOST/$1" ] || { all_match=false; break; }
    done <<EOF
$urls
EOF
    [ "$all_match" = true ] && { printf '%s' "$r"; return 0; }
  done
  return 1
}
PUSH_REMOTE=$(remote_for "$HEAD_OWNER/$HEAD_REPO" --push) || {
  PUSH_REMOTE=origin
  stop "no local remote points at $HEAD_OWNER/$HEAD_REPO (the PR head repo) -- add one before pushing, e.g.: git remote add fork https://github.com/$HEAD_OWNER/$HEAD_REPO.git"
}
BASE_REMOTE=$(remote_for "$BASE_OWNER/$BASE_REPO") && BASE_REMOTE_FOUND=true || {
  BASE_REMOTE="$PUSH_REMOTE"
  BASE_REMOTE_FOUND=false
}

LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
LOCAL_HEAD=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')

# Fetch from the push URL explicitly -- $PUSH_REMOTE was selected by
# matching its push URL, but `git fetch <remote-name>` resolves that
# remote's fetch URL, which can point elsewhere when the two diverge.
PUSH_URL=$(git remote get-url --push "$PUSH_REMOTE")
$GIT_FETCH --quiet "$PUSH_URL" \
  "+refs/heads/$HEAD_BRANCH:refs/remotes/$PUSH_REMOTE/$HEAD_BRANCH" 2>/dev/null || \
  warn "could not fetch $PUSH_REMOTE/$HEAD_BRANCH; Remote HEAD/ahead-behind below may be stale"
REMOTE_REF="refs/remotes/$PUSH_REMOTE/$HEAD_BRANCH"
REMOTE_HEAD=$(git rev-parse --verify --quiet "$REMOTE_REF" || printf '')
[ -z "$REMOTE_HEAD" ] || [ "$REMOTE_HEAD" = "$HEAD_OID" ] || \
  warn "fetched remote head ($REMOTE_HEAD) does not match the PR's reported head ($HEAD_OID) -- the fetch may have hit a stale cached ref or read the wrong repo; don't trust Ahead/behind below without investigating"

AHEAD=?; BEHIND=?
if [ -n "$REMOTE_HEAD" ]; then
  AHEAD=$(git rev-list --count "$REMOTE_REF..HEAD" 2>/dev/null)
  BEHIND=$(git rev-list --count "HEAD..$REMOTE_REF" 2>/dev/null)
fi

# Fetch the base branch too, same as the head fetch above -- otherwise
# BASE_REF below can resolve to a stale or entirely absent ref. When
# BASE_REMOTE_FOUND is false, $BASE_REMOTE is just $PUSH_REMOTE (the fork)
# reused as a fallback name -- fetching "$BASE_BRANCH" from *that* remote's
# URL would silently pull the fork's own (possibly diverged) branch and
# label it the base, not the true base repo. Fetch directly from the base
# repo's URL in that case instead, and land it under a ref name that can't
# collide with a real remote's tracking refs.
if [ "$BASE_REMOTE_FOUND" = true ]; then
  BASE_URL=$(git remote get-url "$BASE_REMOTE" 2>/dev/null) || BASE_URL=""
  BASE_FETCH_REF="refs/remotes/$BASE_REMOTE/$BASE_BRANCH"
else
  BASE_URL="https://$PR_HOST/$BASE_OWNER/$BASE_REPO.git"
  BASE_FETCH_REF="refs/pr-review-loop/base/$BASE_BRANCH"
fi
[ -z "$BASE_URL" ] || $GIT_FETCH --quiet "$BASE_URL" \
  "+refs/heads/$BASE_BRANCH:$BASE_FETCH_REF" 2>/dev/null || \
  warn "could not fetch $BASE_BRANCH from $BASE_OWNER/$BASE_REPO; base diff below may be stale or unavailable"

BASE_REF=""
for cand in "$BASE_FETCH_REF" "refs/remotes/origin/$BASE_BRANCH" "refs/heads/$BASE_BRANCH"; do
  git rev-parse --verify --quiet "$cand" >/dev/null && { BASE_REF="$cand"; break; }
done
if [ -n "$BASE_REF" ]; then
  BRANCH_COMMITS=$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null)
else
  BRANCH_COMMITS="? (no local ref for $BASE_BRANCH)"
  warn "no local ref resolves the base branch '$BASE_BRANCH' -- diffing against it will fail; fetch it manually before scoping a diff"
fi

LAST_SHA=$(git log -1 --format=%h)
LAST_SUBJ=$(git log -1 --format=%s)
LAST_AUTHOR=$(git log -1 --format='%an <%ae>')
LAST_AGE=$(git log -1 --format=%cr)
LAST_EMAIL=$(git log -1 --format=%ae)
LAST_PARENTS=$(git log -1 --format=%p | wc -w | tr -d ' ')
GIT_EMAIL=$(git config user.email)
MINE=no; [ "$LAST_EMAIL" = "$GIT_EMAIL" ] && MINE=yes
PUSHED=no; [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] && PUSHED=yes

# --- hard stops -------------------------------------------------------------
[ "$STATE" = "OPEN" ] || stop "PR is $STATE, not OPEN"
[ "$LOCAL_BRANCH" = "$HEAD_BRANCH" ] || \
  stop "checked out '$LOCAL_BRANCH' but PR head is '$HEAD_BRANCH' -- run: gh pr checkout $NUMBER"
[ "$HEAD_BRANCH" != "$DEFAULT_BRANCH" ] || \
  stop "PR head is the default branch ($DEFAULT_BRANCH) of $HEAD_OWNER/$HEAD_REPO -- never force-push here"
case "$HEAD_BRANCH" in
  main|master|develop|trunk|release) stop "head branch '$HEAD_BRANCH' looks shared -- do not force-push it" ;;
esac

# --- warnings ---------------------------------------------------------------
[ "$DIRTY" = "0" ] || warn "$DIRTY uncommitted change(s) present -- decide what belongs in this round before committing"
[ "${BEHIND}" = "0" ] || [ "$BEHIND" = "?" ] || stop "local branch is $BEHIND commit(s) behind $PUSH_REMOTE/$HEAD_BRANCH -- pull/rebase before pushing or amending (--force-with-lease will not catch this)"
[ "$IS_FORK" = false ] || warn "head is a fork; push to remote '$PUSH_REMOTE', not the base repo -- if pr-preflight STOPPED above, add a matching remote first"
[ "$DRAFT" != true ] || warn "PR is a draft; Copilot may not review until it is marked ready"
[ "$MINE" = yes ] || warn "HEAD commit was authored by $LAST_EMAIL, not you -- do NOT amend it"
[ "$LAST_PARENTS" -le 1 ] || warn "HEAD is a merge commit -- do NOT amend it"

# Shell-escaped for the printed push/force commands (and Base ref) below --
# HEAD_BRANCH and BASE_BRANCH are both PR-controlled (a PR can name either
# branch anything a valid git ref allows, including shell metacharacters
# like $() or backticks -- `git check-ref-format` permits them) and these
# values are meant to be copied verbatim into a shell, so they must already
# be escaped by the time they're pasted -- never trust "it's just a ref
# path" to make raw substitution safe.
Q_PUSH_REMOTE=$(printf '%q' "$PUSH_REMOTE")
Q_HEAD_BRANCH=$(printf '%q' "$HEAD_BRANCH")
Q_BASE_REF=$(printf '%q' "$BASE_REF")

cat <<EOF
PR             $BASE_OWNER/$BASE_REPO#$NUMBER  ($STATE, draft=$DRAFT, mergeState=$MERGE_STATE)
URL            $PR_URL
Base branch    $BASE_BRANCH  (remote: $BASE_REMOTE, found=$BASE_REMOTE_FOUND)
Base ref       $([ -n "$BASE_REF" ] && echo "$Q_BASE_REF" || echo "<none -- see WARN below>")
Head branch    $HEAD_BRANCH  (fork=$IS_FORK, head repo default branch=$DEFAULT_BRANCH)
Head repo      $HEAD_OWNER/$HEAD_REPO
Repo root      $REPO_ROOT
Local branch   $LOCAL_BRANCH
Local HEAD     $LOCAL_HEAD
Remote HEAD    ${REMOTE_HEAD:-<branch not on remote>}  ($PUSH_REMOTE/$HEAD_BRANCH)
PR head oid    $HEAD_OID
Ahead/behind   ahead=$AHEAD behind=$BEHIND
Work tree      $([ "$DIRTY" = 0 ] && echo clean || echo "$DIRTY changed file(s)")
Commits on br  $BRANCH_COMMITS
Push command   git push $Q_PUSH_REMOTE HEAD:refs/heads/$Q_HEAD_BRANCH
Force command  git push --force-with-lease $Q_PUSH_REMOTE HEAD:refs/heads/$Q_HEAD_BRANCH
HEAD commit    $LAST_SHA "$LAST_SUBJ"
  author       $LAST_AUTHOR ($LAST_AGE)
  yours        $MINE
  pushed       $PUSHED
  parents      $LAST_PARENTS
CHECKS$STOPS$WARNS
$([ -z "$STOPS$WARNS" ] && echo "  all clear")
EOF

[ -z "$STOPS" ] || exit 1
