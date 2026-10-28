#!/usr/bin/env bash
# Shared helpers for the pr-review-loop scripts. Source it from a script with:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# Requirements: bash 3.2+ (the stock macOS bash), `gh`, and `jq`. Nothing else.
# Keep this file bash-3.2 clean: no associative arrays, no `mapfile`, no `${var,,}`.
#
# Sourcing it does NOT call the network. A missing/unauthenticated `gh` is reported by
# the first real call (see gh_capture), so a transient `gh auth status` failure -- e.g.
# a keyring timeout -- can't abort a run that would otherwise have worked.

set -euo pipefail

# Copilot's reviewer login is `copilot-pull-request-reviewer` when it appears as a
# requested reviewer and `copilot-pull-request-reviewer[bot]` as a review author, so
# callers must accept both. Used with jq's test($rx; "i"). Defined once so every
# script stays in sync.
COPILOT_LOGIN_REGEX='^copilot-pull-request-reviewer(\[bot\])?$'

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

# Fail fast, with install instructions, if a required tool is missing.
require_tools() {
  command -v gh >/dev/null 2>&1 || die "pr-review-loop: prerequisite missing — \`gh\` is not on PATH.

Install:  brew install gh
Then:     gh auth login
and re-run this command."
  command -v jq >/dev/null 2>&1 || die "pr-review-loop: prerequisite missing — \`jq\` is not on PATH.

Install:  brew install jq
and re-run this command."
}

# Used in each script's argument loop: `--pr) need_value $# --pr; PR=$2; shift 2 ;;`.
# Without it a trailing flag with no value makes `shift 2` fail: silently under `set -e`, and
# as an endless loop in a script that doesn't use it.
need_value() { # $# flag
  [ "$1" -ge 2 ] || die "$2 requires a value."
}

# Validate that $2 is a positive integer, naming it $1 in the error.
require_int() {
  case "$2" in
    '' | *[!0-9]*) die "$1 must be a positive integer (got '$2')." ;;
  esac
}

# Run `gh` with the given args, capturing stdout, stderr, and the exit code separately.
# Sets the globals GH_STDOUT, GH_STDERR, GH_EXIT (no subshell, so callers can read them).
# Retries transient failures (5xx, timeouts, connection errors) GH_RETRIES times
# (default 0). Only set GH_RETRIES for READS: retrying a mutation whose response was
# lost could apply it twice.
GH_RETRIES=${GH_RETRIES:-0}
gh_capture() {
  local errfile attempt=0
  errfile=$(mktemp "${TMPDIR:-/tmp}/pr-review-loop.XXXXXX")
  while :; do
    GH_STDOUT=$(gh "$@" 2>"$errfile") && GH_EXIT=0 || GH_EXIT=$?
    GH_STDERR=$(cat "$errfile")
    if [ "$GH_EXIT" -ne 0 ] && [ "$attempt" -lt "$GH_RETRIES" ] &&
      printf '%s' "$GH_STDERR" | grep -Eiq 'HTTP 5[0-9][0-9]|time(d )?out|connection (reset|refused)|EOF|TLS|temporar'; then
      attempt=$((attempt + 1))
      sleep $((attempt * 2))
      continue
    fi
    break
  done
  rm -f "$errfile"
  # Translate an auth failure into the single actionable message agents can pattern-match.
  if [ "$GH_EXIT" -ne 0 ] && printf '%s' "$GH_STDERR" | grep -Eiq 'gh auth login|not logged in|bad credentials|HTTP 401'; then
    die "pr-review-loop: prerequisite missing — \`gh\` is not authenticated.

Run:  gh auth login
then re-run this command.

\`gh\` reported:
  $GH_STDERR"
  fi
}

# Run a GraphQL call and print the response JSON. Dies on a non-zero exit, on non-JSON
# output, or on a GraphQL `errors` array (reporting type/path/code alongside message so
# failures are actionable). Call as `data=$(gh_graphql "context" -f query=... )`; do not
# prefix with `local`, which would swallow the failure status.
gh_graphql() {
  local ctx=$1 errs
  shift
  gh_capture api graphql "$@"
  if [ "$GH_EXIT" -ne 0 ]; then
    die "gh api graphql failed (exit $GH_EXIT) [$ctx]: $GH_STDERR"
  fi
  if ! printf '%s' "$GH_STDOUT" | jq -e . >/dev/null 2>&1; then
    die "gh api graphql [$ctx] returned non-JSON.
stdout (<=500 chars): $(printf '%s' "$GH_STDOUT" | cut -c1-500)
stderr (<=500 chars): $(printf '%s' "$GH_STDERR" | cut -c1-500)"
  fi
  errs=$(printf '%s' "$GH_STDOUT" | jq -r '
    (.errors // [])
    | map([
        (if .type then "type=\(.type)" else empty end),
        (if .path then "path=\(.path | map(tostring) | join("/"))" else empty end),
        (if (.extensions.code? // null) then "code=\(.extensions.code)" else empty end),
        "message=\(.message)"
      ] | join(" "))
    | join("; ")')
  [ -z "$errs" ] || die "GraphQL errors [$ctx]: $errs"
  printf '%s\n' "$GH_STDOUT"
}

# gh_graphql for READS: retries transient failures twice.
gh_graphql_read() {
  local GH_RETRIES=2
  gh_graphql "$@"
}

# Resolve OWNER/REPO. Pass both or neither: mixing a caller-supplied owner with a
# locally detected repo (or vice versa) would silently build a wrong `<owner>/<repo>`.
# Without them, `gh repo view` reads the repo from the CURRENT DIRECTORY's git remote,
# so run the scripts from inside the target repo (or pass --owner and --repo).
resolve_repo() {
  if { [ -n "${OWNER:-}" ] && [ -z "${REPO:-}" ]; } || { [ -z "${OWNER:-}" ] && [ -n "${REPO:-}" ]; }; then
    die "resolve_repo: pass both --owner and --repo, or neither (got owner='${OWNER:-}' repo='${REPO:-}'). A partial override would silently mix caller and local repo coordinates."
  fi
  [ -z "${OWNER:-}" ] || return 0
  GH_RETRIES=2 gh_capture repo view --json owner,name
  [ "$GH_EXIT" -eq 0 ] || die "gh repo view failed (exit $GH_EXIT): $GH_STDERR. Pass --owner and --repo explicitly, or run from inside a gh-detected repo."
  OWNER=$(printf '%s' "$GH_STDOUT" | jq -r '.owner.login // empty')
  REPO=$(printf '%s' "$GH_STDOUT" | jq -r '.name // empty')
  [ -n "$OWNER" ] && [ -n "$REPO" ] || die "gh repo view returned an unexpected shape (missing owner.login or name); pass --owner and --repo explicitly."
}

# Login of the authenticated gh user, into ME.
resolve_me() {
  GH_RETRIES=2 gh_capture api user --jq .login
  [ "$GH_EXIT" -eq 0 ] || die "gh api user failed (exit $GH_EXIT): $GH_STDERR"
  ME=$GH_STDOUT
}

# jq definitions for judging a Copilot review body. Prepend to a jq program as
# "$JQ_REVIEW_LIB ...". Each takes the review body string as input.
#
# previously_missed_count: findings Copilot lists under a "Previously missed (N)" or
#   "N previously missed issue(s)" section
#   in the review body. They are real findings in code that hadn't changed since the last
#   review but are NOT review threads, so 03-list-open-threads.sh can't see them and
#   there is no thread to reply to or resolve. 0 when the section is absent. Only the
#   SECTION HEADING counts: a <summary> whose text starts with it, or a line that starts
#   with it (optionally after markdown heading/bold/bullet markers). The phrase anywhere
#   else (PR-overview prose, or the title of a finding about this very feature) is not a
#   section.
#
# review_clean: does the body say "nothing for the agent to address"? Terminal for the
#   loop.
#   - A body listing any "Previously missed" finding is never clean, even when its
#     header says "0 open findings": those findings are unthreaded and still need
#     handling.
#   - Current format (<!-- ccr-overview-v2 -->): a standalone "**0 open findings**" or
#     "**No open issues**" line (optionally followed by 🎉) in
#     the header, i.e. BEFORE the first collapsed <details>. The phrase inside the
#     collapsed overview or findings sections (an example, prose about this feature) is
#     not the review's own count: a review reporting "**2 open findings**" must not read
#     as clean because its overview quotes "**0 open findings**".
#   - Older phrasing: "generated no new comments" / "generated 0 comments", and the
#     "wasn't able to review any files in this pull request" body for empty diffs. Like the
#     current format, only counted in the header (before the first collapsed <details>):
#     a review reporting findings must not read as clean because its overview or a
#     finding quotes the phrase.
#     Anchored on \b and a following sentence end (./!/EOL/EOS) so it does NOT match
#     substrings like "generated no comments yet but...".
#   "Clean" means the agent has nothing to fix, NOT that no human action is requested:
#   see review_heading / review_summary.
#
# review_heading: the verdict in the review's header line, e.g. "Approved", "Changes
#   recommended", or "Needs a closer look" (the leading emoji is dropped). null if the
#   body has no recognizable header.
#
# review_summary: the sentence under that header. For "Needs a closer look" it often asks
#   a human to confirm something (e.g. production preflight checks) even when there are 0
#   findings, so it must be surfaced to the user, never silently dropped. null if absent.
# shellcheck disable=SC2016  # the jq program is deliberately single-quoted
JQ_REVIEW_LIB='
def pm_prefix: "(?:<summary[^>]*>\\s*(?:<[^>]+>\\s*)*|(?:^|\\n)[ \\t]*(?:[#>*_-]+[ \\t]*)*)";
def previously_missed_count:
  if test(pm_prefix + "Previously\\s+missed\\s*\\(\\d+\\)"; "i")
  then (capture(pm_prefix + "Previously\\s+missed\\s*\\((?<n>\\d+)\\)"; "i") | .n | tonumber)
  elif test(pm_prefix + "\\d+\\s+previously\\s+missed\\s+issues?\\b"; "i")
  then (capture(pm_prefix + "(?<n>\\d+)\\s+previously\\s+missed\\s+issues?\\b"; "i") | .n | tonumber)
  elif test("<summary[^>]*>\\s*(?:<[^>]+>\\s*)*Previously\\s+missed"; "i") then 1
  else 0 end;
def review_header: (. // "") | split("<details")[0];
def review_clean:
  if . == null or . == "" then false
  elif previously_missed_count > 0 then false
  elif (review_header | test("(?:^|\\n)[ \\t]*\\*\\*(?:0 open findings|No open issues)\\*\\*[ \\t]*(?:🎉[ \\t]*)?(?:\\r?\\n|$)"; "i")) then true
  else (review_header | test("\\b(?:generated|had|with)\\s+(?:no|0|zero)\\s+(?:new\\s+)?comments\\s*(?:[.!]|\\r?\\n|$)|wasn.?t\\s+able\\s+to\\s+review\\s+any\\s+files\\s+in\\s+this\\s+pull\\s+request|was\\s+not\\s+able\\s+to\\s+review\\s+any\\s+files\\s+in\\s+this\\s+pull\\s+request"; "i"))
  end;
def review_heading:
  ((. // "") | capture("(?:^|\\n)#{1,6}[ \\t]+\\S+[ \\t]+(?<h>[^\\n]+)") | .h | sub("[ \\t\\r]+$"; "")) // null;
def review_summary:
  ((. // "") | capture("(?:^|\\n)#{1,6}[ \\t]+\\S+[ \\t]+[^\\n]+\\n+(?<s>[^\\n<*#][^\\n]*)") | .s | sub("[ \\t\\r]+$"; "")) // null;
'

# Invisible marker that 08-reply-and-resolve.sh appends to any reply posted with
# --no-resolve (an escalation to a human, or a discussion left open on purpose). It is how
# 10-cleanup-outdated.sh tells a thread we deliberately left open from one we simply
# forgot to resolve, with no state kept between runs. Never resolve a thread whose last
# comment carries it.
HANDOFF_MARKER='<!-- pr-review-loop:handoff -->'

# Scratch space for big JSON. Passing a large value to jq as `--argjson x "$big"` puts it
# on the command line and can fail with "Argument list too long" (a single argument is
# capped at 128 KB on Linux, and the total at about 1 MB on macOS). Keep big values in
# files under $WORK and read them with `--slurpfile` or stdin instead. Cleaned up on exit.
make_workdir() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-loop.XXXXXX")
  # shellcheck disable=SC2064  # expand $WORK now: the trap must remove this directory
  trap "rm -rf '$WORK'" EXIT
}
