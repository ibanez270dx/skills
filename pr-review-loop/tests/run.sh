#!/usr/bin/env bash
# Offline tests for the pr-review-loop scripts. A fake `gh` (tests/bin/gh) serves canned
# responses, so nothing here touches the network or a real PR.
#
#   .claude/skills/pr-review-loop/tests/run.sh
#
# Needs bash 3.2+ and jq. Exits non-zero if any assertion fails.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=$(cd "$HERE/../scripts" && pwd)
export PATH="$HERE/bin:$PATH"
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $3 | actual: $2"; fi
}
assert_contains() { # name haystack needle
  case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain: $3 | actual: $2" ;; esac
}
assert_not_contains() { # name haystack needle
  case $2 in *"$3"*) bad "$1" "expected NOT to contain: $3 | actual: $2" ;; *) ok "$1" ;; esac
}
jqv() { printf '%s' "$1" | jq -r "$2"; } # json filter

new_scenario() {
  FAKE_GH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/prl-test.XXXXXX")
  export FAKE_GH_DIR
  echo '{"owner":{"login":"acme"},"name":"widgets"}' >"$FAKE_GH_DIR/repo.json"
  echo 'me-bot' >"$FAKE_GH_DIR/me"
  : >"$FAKE_GH_DIR/gh.log"
}

# ---------- fixture builders ----------
review() { # login state submittedAt commitOid body
  jq -cn --arg l "$1" --arg s "$2" --arg t "$3" --arg c "$4" --arg b "$5" \
    '{author:{login:$l},state:$s,submittedAt:$t,body:$b,commit:{oid:$c}}'
}
write_head() { # state headOid reviews_json
  jq -cn --arg st "$1" --arg h "$2" --argjson rv "$3" \
    '{data:{repository:{pullRequest:{headRefOid:$h,state:$st,reviews:{nodes:$rv}}}}}' >"$FAKE_GH_DIR/head.json"
}
page() { # key nodes_json hasNext endCursor  -> {data:{repository:{pullRequest:{<key>:{pageInfo,nodes}}}}}
  jq -cn --arg k "$1" --argjson n "$2" --argjson h "$3" --arg c "$4" \
    '{data:{repository:{pullRequest:{($k):{pageInfo:{hasNextPage:$h,endCursor:$c},nodes:$n}}}}}'
}
thread02() { # resolved lastAuthor("" = ghost)
  jq -cn --argjson r "$1" --arg a "$2" \
    '{isResolved:$r,comments:{nodes:[{author:(if $a == "" then null else {login:$a} end)}]}}'
}
copilot_request() { echo '{"requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}'; }

CLEAN=$'### 🟢 Approved\n\n**0 open findings**'
MISSED=$'**0 open findings**\n\n<details><summary><strong>Previously missed (1)</strong></summary>real finding</details>'
FINDINGS=$'**2 open findings**'
HEAD=abc123
OLD=zzz999

# ======================================================================
echo "review_clean / previously_missed_count (jq library)"
# shellcheck disable=SC1091
. "$SCRIPTS/_lib.sh"
set +e +o pipefail # _lib.sh turns these on; tests below run failing commands on purpose
clean() { jq -rn --arg b "$1" "$JQ_REVIEW_LIB"'$b | review_clean'; }
missed() { jq -rn --arg b "$1" "$JQ_REVIEW_LIB"'$b | previously_missed_count'; }
assert_eq 'current format, 0 open findings' "$(clean "$CLEAN")" true
ISSUES_CLEAN=$'<!-- ccr-overview-v2 -->\n\n### 🟢 Approved\n\nAll concerns addressed.\n\n**No open issues** 🎉\n\n<details>Overview</details>'
ISSUES_MISSED=$'<!-- ccr-overview-v2 -->\n\n### 🔵 Needs a closer look\n\nA real finding remains.\n\n**No open issues** 🎉\n\n<details>\n<summary><strong>1 previously missed issue</strong></summary>real finding</details>'
assert_eq 'current format, No open issues with celebration' "$(clean "$ISSUES_CLEAN")" true
assert_eq 'current format, No open issues without celebration' "$(clean '**No open issues**')" true
assert_eq 'No open issues but count-first previously missed issue' "$(clean "$ISSUES_MISSED")" false
assert_eq 'count-first previously missed actual review body' "$(missed "$ISSUES_MISSED")" 1
assert_eq 'count-first previously missed plural heading' "$(missed '<summary><strong>3 previously missed issues</strong></summary>')" 3
assert_eq 'count-first previously missed markdown heading' "$(missed $'intro\n### 2 previously missed issues\nfinding')" 2
assert_eq 'NOT missed: count-first phrase in overview prose' "$(missed 'What changed: fixes 2 previously missed issues.')" 0
assert_eq 'NOT clean: No open issues quoted inside details' "$(clean $'### 🟡 Changes recommended\n\n**2 open issues**\n\n<details>\n**No open issues** 🎉\n</details>')" false
assert_eq 'NOT clean: No open issues inline in prose' "$(clean 'An example says **No open issues** 🎉')" false
assert_eq 'NOT clean: No open issues followed by more prose' "$(clean '**No open issues** but review is pending')" false
assert_eq '0 open findings but Previously missed' "$(clean "$MISSED")" false
assert_eq 'N open findings' "$(clean "$FINDINGS")" false
HDR_BAD=$'### 🔵 Needs a closer look\n\nSummary.\n\n**2 open findings**\n\n<details><summary>What changed</summary>Example: **0 open findings** in a clean review.</details>'
assert_eq 'NOT clean: header reports 2 findings, overview quotes **0 open findings**' "$(clean "$HDR_BAD")" false
assert_eq 'NOT clean: **0 open findings** only appears inside <details>' "$(clean $'### Header\n\nSummary.\n\n<details>x\n**0 open findings**\n</details>')" false
assert_eq 'clean: the standalone line sits in the header, details follow' "$(clean $'### 🟢 Approved\n\n**0 open findings**\n\n<details>Overview: **2 open findings** would be bad</details>')" true
assert_eq 'NOT clean: **0 open findings** inline in a sentence, not a standalone line' "$(clean $'### Header\n\nThis review has **0 open findings** as discussed.')" false
LEGACY_QUOTED=$'### Changes recommended\n\n**2 open findings**\n\n<details><summary>What changed</summary>A clean review says: Copilot generated no new comments.</details>'
assert_eq 'NOT clean: header reports findings, a collapsed section quotes "generated no new comments."' "$(clean "$LEGACY_QUOTED")" false
assert_eq 'older: generated no new comments.' "$(clean 'generated no new comments.')" true
assert_eq 'older: generated 0 comments' "$(clean 'Copilot reviewed and generated 0 comments')" true
assert_eq 'older: generated no comments yet but...' "$(clean 'generated no comments yet but more to come')" false
assert_eq 'older: with 0 comments outstanding' "$(clean 'with 0 comments outstanding')" false
assert_eq "older: wasn't able to review any files" "$(clean "Copilot wasn't able to review any files in this pull request")" true
assert_eq 'empty body' "$(clean '')" false
assert_eq 'missed count parsed (line start)' "$(missed 'Previously missed (3)')" 3
assert_eq 'missed count absent' "$(missed 'nothing here')" 0
assert_eq 'missed: <summary> section heading' "$(missed '<details><summary><strong>Previously missed (2)</strong></summary>x</details>')" 2
assert_eq 'missed: markdown heading' "$(missed $'intro\n### Previously missed (1)\nfinding')" 1
assert_eq 'missed: <summary> without a count' "$(missed '<summary><strong>Previously missed</strong></summary>')" 1
assert_eq 'NOT missed: overview prose mentioning the feature' "$(missed 'What changed: adds handling for Previously missed findings in the review body.')" 0
assert_eq 'NOT missed: a finding whose title mentions it' "$(missed '- [Restrict Previously missed detection to the findings section](https://x/y) · New')" 0
assert_eq 'clean despite overview prose about Previously missed' "$(clean $'### 🟢 Approved\n\n**0 open findings**\n\nAdds handling for Previously missed findings.')" true
heading() { jq -rn --arg b "$1" "$JQ_REVIEW_LIB"'$b | review_heading // "null"'; }
summary() { jq -rn --arg b "$1" "$JQ_REVIEW_LIB"'$b | review_summary // "null"'; }
CLOSER=$'<!-- ccr-overview-v2 -->\n\n### 🔵 Needs a closer look\n\nProduction preflight checks need human confirmation.\n\n**0 open findings**\n\n<details>x</details>'
assert_eq 'heading: Needs a closer look' "$(heading "$CLOSER")" 'Needs a closer look'
assert_eq 'summary: the sentence under the header' "$(summary "$CLOSER")" 'Production preflight checks need human confirmation.'
assert_eq 'heading: Approved' "$(heading "$CLEAN")" 'Approved'
assert_eq 'heading: Changes recommended' "$(heading $'### 🟡 Changes recommended\n\nFix the constraint.')" 'Changes recommended'
assert_eq 'heading: none -> null' "$(heading 'generated no new comments.')" null
assert_eq 'summary: none -> null' "$(summary '')" null

# ======================================================================
echo "02-check-review-status: convergence matrix"
run02() { "$SCRIPTS/02-check-review-status.sh" --pr 7 "$@" 2>&1; }
setup02() { # state reviews_json threads_json requests_json
  new_scenario
  write_head "$1" "$HEAD" "$2"
  page reviewThreads "$3" false null >"$FAKE_GH_DIR/threads_first.json"
  page reviewRequests "$4" false null >"$FAKE_GH_DIR/requests_first.json"
}
R_CLEAN=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $HEAD "$CLEAN")" '[$a]')

R=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $HEAD "$ISSUES_CLEAN")" '[$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'No open issues at HEAD -> converged' "$(jqv "$out" '[.NoNewComments, .PreviouslyMissedCount, .Converged] | @csv')" 'true,0,true'
R=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $HEAD "$ISSUES_MISSED")" '[$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'No open issues plus count-first missed finding -> NOT converged' "$(jqv "$out" '[.NoNewComments, .PreviouslyMissedCount, .Converged] | @csv')" 'false,1,false'

R=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $HEAD "$CLOSER")" '[$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'Needs a closer look + 0 findings: surfaced for hand-off, does not block Converged' "$(jqv "$out" '[.ReviewVerdict, .ReviewSummary, .Converged] | @csv')" '"Needs a closer look","Production preflight checks need human confirmation.",true'

setup02 OPEN "$R_CLEAN" '[]' "$(jq -cn --argjson a "$(copilot_request)" '[$a]')"
out=$(run02)
assert_eq 'clean review at HEAD but another review is still pending -> NOT converged' "$(jqv "$out" '[.ReviewAtHead, .NoNewComments, .CopilotPending, .Converged] | @csv')" 'true,true,true,false'
out=$(run02 --single-iteration)
assert_eq '  --single-iteration is unchanged by a pending review' "$(jqv "$out" .Converged)" true

setup02 OPEN "$R_CLEAN" '[]' '[]'
out=$(run02)
assert_eq 'clean review at HEAD, no threads -> Converged' "$(jqv "$out" .Converged)" true
assert_eq '  ReviewAtHead' "$(jqv "$out" .ReviewAtHead)" true
assert_eq '  ReviewVerdict' "$(jqv "$out" .ReviewVerdict)" Approved
assert_eq '  LatestCopilotReview.commitOid' "$(jqv "$out" .LatestCopilotReview.commitOid)" $HEAD
assert_eq '  output key order' "$(jqv "$out" 'keys_unsorted | join(",")')" \
  'PrNumber,Owner,Repo,HeadOid,State,LatestCopilotReview,ReviewAtHead,NoNewComments,PreviouslyMissedCount,ReviewVerdict,ReviewSummary,OpenThreadCount,OpenThreadsAwaitingReply,CopilotPending,Converged'

R=$(jq -cn --argjson a "$(review 'copilot-pull-request-reviewer[bot]' COMMENTED 2026-01-02T00:00:00Z $HEAD "$MISSED")" '[$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'Previously missed -> NOT converged' "$(jqv "$out" .Converged)" false
assert_eq '  NoNewComments false' "$(jqv "$out" .NoNewComments)" false
assert_eq '  PreviouslyMissedCount' "$(jqv "$out" .PreviouslyMissedCount)" 1
assert_eq '  [bot] login accepted' "$(jqv "$out" .LatestCopilotReview.state)" COMMENTED

R=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $OLD "$CLEAN")" '[$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'review on an older commit -> not converged' "$(jqv "$out" .Converged)" false
assert_eq '  ReviewAtHead false' "$(jqv "$out" .ReviewAtHead)" false

R=$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-01T00:00:00Z $HEAD "$FINDINGS")" \
  --argjson b "$(review copilot-pull-request-reviewer COMMENTED 2026-01-03T00:00:00Z $OLD "$CLEAN")" '[$b,$a]')
setup02 OPEN "$R" '[]' '[]'
out=$(run02)
assert_eq 'prefers the review whose commit is HEAD over a newer one' "$(jqv "$out" .LatestCopilotReview.commitOid)" $HEAD

setup02 OPEN "$R_CLEAN" "$(jq -cn --argjson a "$(thread02 false copilot-pull-request-reviewer)" '[$a]')" '[]'
out=$(run02)
assert_eq 'open thread, Copilot spoke last -> awaiting reply, not converged' "$(jqv "$out" '[.OpenThreadsAwaitingReply, .Converged] | @csv')" '1,false'

setup02 OPEN "$R_CLEAN" "$(jq -cn --argjson a "$(thread02 false me-bot)" '[$a]')" '[]'
out=$(run02)
assert_eq 'open thread, WE spoke last -> hand-off, still converged' "$(jqv "$out" '[.OpenThreadCount, .OpenThreadsAwaitingReply, .Converged] | @csv')" '1,0,true'

setup02 OPEN "$R_CLEAN" "$(jq -cn --argjson a "$(thread02 false '')" '[$a]')" '[]'
out=$(run02)
assert_eq 'ghost (null) author on the last comment counts as awaiting' "$(jqv "$out" .OpenThreadsAwaitingReply)" 1

setup02 OPEN "$R_CLEAN" "$(jq -cn --argjson a "$(thread02 true copilot-pull-request-reviewer)" '[$a]')" '[]'
out=$(run02)
assert_eq 'resolved threads are ignored' "$(jqv "$out" '[.OpenThreadCount, .Converged] | @csv')" '0,true'

setup02 MERGED "$R_CLEAN" '[]' '[]'
out=$(run02)
assert_eq 'merged PR -> never converged' "$(jqv "$out" '[.State, .Converged] | @csv')" '"MERGED",false'

setup02 OPEN '[]' '[]' "$(jq -cn --argjson a "$(copilot_request)" '[$a]')"
out=$(run02)
assert_eq 'Copilot pending, no review yet -> not converged' "$(jqv "$out" '[.CopilotPending, .LatestCopilotReview == null, .Converged] | @csv')" 'true,true,false'

setup02 OPEN '[]' '[]' '[]'
out=$(run02)
assert_eq '  no review -> verdict and summary are null' "$(jqv "$out" '[.ReviewVerdict, .ReviewSummary] | tojson')" '[null,null]'
assert_eq 'no Copilot review ever, none pending, no threads -> converged (nothing to do yet)' "$(jqv "$out" '[.LatestCopilotReview == null, .Converged] | @csv')" 'true,true'

setup02 OPEN "$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $OLD "$FINDINGS")" '[$a]')" '[]' '[]'
out=$(run02 --single-iteration)
assert_eq '--single-iteration ignores the stale review' "$(jqv "$out" .Converged)" true

new_scenario
write_head OPEN $HEAD "$R_CLEAN"
page reviewThreads "$(jq -cn --argjson a "$(thread02 false me-bot)" '[$a]')" true cursor1 >"$FAKE_GH_DIR/threads_first.json"
page reviewThreads "$(jq -cn --argjson a "$(thread02 false other-user)" '[$a]')" false null >"$FAKE_GH_DIR/threads_cursor1.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
out=$(run02)
assert_eq 'threads are paginated (2 pages, 1 awaiting)' "$(jqv "$out" '[.OpenThreadCount, .OpenThreadsAwaitingReply] | @csv')" '2,1'

new_scenario
write_head OPEN $HEAD "$R_CLEAN"
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests "$(jq -cn --argjson a '{"requestedReviewer":{"__typename":"User","login":"human"}}' '[$a]')" true rc1 >"$FAKE_GH_DIR/requests_first.json"
page reviewRequests "$(jq -cn --argjson a "$(copilot_request)" '[$a]')" false null >"$FAKE_GH_DIR/requests_rc1.json"
out=$(run02)
assert_eq 'reviewRequests are paginated (Copilot found on page 2)' "$(jqv "$out" .CopilotPending)" true

# A review lands BETWEEN the reads: the first read sees only an older clean review at HEAD,
# a later read sees a newer one that has body-only findings. The snapshot must be retried,
# not reported as converged from the stale clean body.
new_scenario
OLD_CLEAN=$(review copilot-pull-request-reviewer COMMENTED 2026-01-01T00:00:00Z $HEAD "$CLEAN")
NEW_MISSED=$(review copilot-pull-request-reviewer COMMENTED 2026-01-02T00:00:00Z $HEAD "$MISSED")
write_head OPEN $HEAD "$(jq -cn --argjson a "$OLD_CLEAN" '[$a]')"
cp "$FAKE_GH_DIR/head.json" "$FAKE_GH_DIR/head_1.json"
write_head OPEN $HEAD "$(jq -cn --argjson a "$OLD_CLEAN" --argjson b "$NEW_MISSED" '[$a,$b]')"
cp "$FAKE_GH_DIR/head.json" "$FAKE_GH_DIR/head_2.json"
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
out=$(run02)
assert_eq 'a review that lands mid-snapshot is picked up by a retry, not reported as converged' "$(jqv "$out" '[.PreviouslyMissedCount, .Converged] | @csv')" '1,false'
assert_eq '  (the snapshot was retaken: head read 4 times)' "$(cat "$FAKE_GH_DIR/head.count")" 4

# Same review COUNT and same newest timestamp, but different contents (as when a new review
# displaces the oldest at the 100-review window limit and shares its timestamp): a fingerprint
# of just count + timestamp would call these equal and accept the stale clean body.
new_scenario
SAME_TS=2026-01-02T00:00:00Z
write_head OPEN $HEAD "$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED $SAME_TS $HEAD "$CLEAN")" '[$a]')"
cp "$FAKE_GH_DIR/head.json" "$FAKE_GH_DIR/head_1.json"
write_head OPEN $HEAD "$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED $SAME_TS $HEAD "$MISSED")" '[$a]')"
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
out=$(run02)
assert_eq 'a swapped review with the same count and timestamp is detected (contents compared)' "$(jqv "$out" '[.PreviouslyMissedCount, .Converged] | @csv')" '1,false'
assert_eq '  (the snapshot was retaken)' "$(cat "$FAKE_GH_DIR/head.count")" 4

# A human replies to a thread AFTER the threads were read, with no new commit or review: the
# head/reviews fingerprint is unchanged, so only re-reading the threads can see it.
new_scenario
write_head OPEN $HEAD "$R_CLEAN"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
page reviewThreads "$(jq -cn --argjson a "$(thread02 false me-bot)" '[$a]')" false null >"$FAKE_GH_DIR/threads_first_1.json"
page reviewThreads "$(jq -cn --argjson a "$(thread02 false alice)" '[$a]')" false null >"$FAKE_GH_DIR/threads_first_2.json"
cp "$FAKE_GH_DIR/threads_first_2.json" "$FAKE_GH_DIR/threads_first.json"
out=$(run02)
assert_eq 'a human reply landing after the threads were read is picked up by a retry' "$(jqv "$out" '[.OpenThreadsAwaitingReply, .Converged] | @csv')" '1,false'
assert_eq '  (threads were re-read: 4 reads)' "$(cat "$FAKE_GH_DIR/threads.count")" 4

# A Copilot review is requested AFTER the review requests were read, again with no new commit or review.
new_scenario
write_head OPEN $HEAD "$R_CLEAN"
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first_1.json"
page reviewRequests "$(jq -cn --argjson a "$(copilot_request)" '[$a]')" false null >"$FAKE_GH_DIR/requests_first_2.json"
cp "$FAKE_GH_DIR/requests_first_2.json" "$FAKE_GH_DIR/requests_first.json"
out=$(run02)
assert_eq 'a Copilot request landing after the requests were read is picked up by a retry' "$(jqv "$out" '[.CopilotPending, .Converged] | @csv')" 'true,false'

# It keeps changing: after 3 attempts it fails closed instead of guessing.
new_scenario
for n in 1 2 3 4 5 6; do
  write_head OPEN $HEAD "$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED "2026-01-0${n}T00:00:00Z" $HEAD "$CLEAN")" '[$a]')"
  cp "$FAKE_GH_DIR/head.json" "$FAKE_GH_DIR/head_$n.json"
done
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
out=$(run02); rc=$?
assert_eq 'a PR that never settles -> fails closed' "$rc" 1
assert_contains '  with an explanation' "$out" 'while it was being read, on 3 consecutive attempts'

out=$("$SCRIPTS/02-check-review-status.sh" --pr abc 2>&1 || true)
assert_contains 'rejects a non-numeric --pr' "$out" '--pr must be a positive integer'
out=$("$SCRIPTS/02-check-review-status.sh" 2>&1 || true)
assert_contains 'requires --pr' "$out" '--pr is required'
out=$("$SCRIPTS/02-check-review-status.sh" --pr 7 --owner x 2>&1 || true)
assert_contains 'rejects --owner without --repo' "$out" 'pass both --owner and --repo, or neither'

# ======================================================================
echo "03-list-open-threads"
new_scenario
mk_thread() { # id resolved author body path line createdAt
  jq -cn --arg id "$1" --argjson r "$2" --arg a "$3" --arg b "$4" --arg p "$5" --argjson l "$6" --arg t "$7" \
    '{id:$id,isResolved:$r,comments:{nodes:[{author:(if $a == "" then null else {login:$a} end),body:$b,path:$p,line:$l,createdAt:$t}]}}'
}
LONGBODY=$(printf 'x%.0s' $(seq 1 30))
nodes=$(jq -cn \
  --argjson a "$(mk_thread T1 false copilot-pull-request-reviewer $'line one\r\nline two' docs/a.md 12 2026-01-01T00:00:00Z)" \
  --argjson b "$(mk_thread T2 true someone 'resolved' docs/b.md 3 2026-01-01T00:00:00Z)" \
  --argjson c "$(mk_thread T3 false '' "$LONGBODY" docs/c.md null 2026-01-02T00:00:00Z)" \
  '[$a,$b,$c]')
page reviewThreads "$nodes" false null >"$FAKE_GH_DIR/threads_first.json"
out=$("$SCRIPTS/03-list-open-threads.sh" --pr 9 --max-body-length 20 2>&1)
assert_eq 'lists only unresolved threads' "$(jqv "$out" '[.OpenThreadCount, (.Threads | map(.ThreadId) | join(","))] | @csv')" '2,"T1,T3"'
assert_eq 'Path is file:line when anchored' "$(jqv "$out" '.Threads[0].Path')" 'docs/a.md:12'
assert_eq 'Path is just the file when not anchored' "$(jqv "$out" '.Threads[1].Path')" 'docs/c.md'
assert_eq 'newlines (incl. CRLF) flatten to spaces' "$(jqv "$out" '.Threads[0].Body')" 'line one line two'
assert_eq 'long bodies truncate with an ellipsis' "$(jqv "$out" '.Threads[1].Body')" "$(printf 'x%.0s' $(seq 1 20))…"
assert_eq 'deleted author is labelled' "$(jqv "$out" '.Threads[1].Author')" '(deleted)'
assert_eq 'CreatedAt passes through' "$(jqv "$out" '.Threads[0].CreatedAt')" '2026-01-01T00:00:00Z'
out=$("$SCRIPTS/03-list-open-threads.sh" --pr 9 --max-body-length 0 2>&1)
assert_eq '--max-body-length 0 disables truncation' "$(jqv "$out" '.Threads[1].Body | length')" 30
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
out=$("$SCRIPTS/03-list-open-threads.sh" --pr 9 2>&1)
assert_eq 'no open threads -> empty array' "$(jqv "$out" '[.OpenThreadCount, (.Threads | length)] | @csv')" '0,0'

echo "03-list-open-threads: conversation context for triage"
new_scenario
cm() { # login body  -> one comment node ("" login = deleted account)
  jq -cn --arg a "$1" --arg b "$2" '{author:(if $a == "" then null else {login:$a} end),body:$b,path:"a.md",line:7,createdAt:"2026-01-01T00:00:00Z"}'
}
conv() { # id totalCount comment...   -> one thread node (lastComment defaults to the last given)
  local id=$1 total=$2; shift 2
  printf '%s\n' "$@" | jq -cs --arg id "$id" --argjson t "$total" '{id:$id,isResolved:false,comments:{totalCount:$t,nodes:.},lastComment:{nodes:[.[-1]]}}'
}
nodes=$(jq -cn \
  --argjson a "$(conv T_human 3 "$(cm copilot-pull-request-reviewer 'Finding')" "$(cm me-bot 'Declined: out of scope')" "$(cm alice 'I disagree, this is a real bug')")" \
  --argjson b "$(conv T_mine 2 "$(cm copilot-pull-request-reviewer 'Finding')" "$(cm me-bot 'Fixed in abc1234')")" \
  --argjson c "$(conv T_ghost 2 "$(cm copilot-pull-request-reviewer 'Finding')" "$(cm '' 'comment from a deleted account')")" \
  --argjson d "$(conv T_long 150 "$(cm copilot-pull-request-reviewer 'Finding')" "$(cm me-bot 'reply')" | jq -c '.lastComment.nodes = [{author:{login:"alice"},body:"objection in comment 101",path:"a.md",line:7,createdAt:"2026-01-02T00:00:00Z"}]')" \
  --argjson e "$(conv T_fresh 1 "$(cm copilot-pull-request-reviewer 'Finding')")" \
  '[$a,$b,$c,$d,$e]')
page reviewThreads "$nodes" false null >"$FAKE_GH_DIR/threads_first.json"
out=$("$SCRIPTS/03-list-open-threads.sh" --pr 9 2>&1)
t() { jqv "$out" ".Threads[] | select(.ThreadId == \"$1\") | $2"; }
assert_eq 'a human reply on a Copilot thread is visible: replies, last author, awaiting' "$(t T_human '[.Author, .LastAuthor, .AwaitingReply, .HumanParticipated, .CommentCount] | @csv')" '"copilot-pull-request-reviewer","alice",true,true,3'
assert_eq '  and the replies carry the earlier decline rationale' "$(t T_human '[.Replies[].Body] | join(" | ")')" 'Declined: out of scope | I disagree, this is a real bug'
assert_eq 'Copilot + our own reply only -> no human, nothing awaiting' "$(t T_mine '[.HumanParticipated, .AwaitingReply, .LastAuthor] | @csv')" 'false,false,"me-bot"'
assert_eq 'a deleted account counts as human (unknown identity)' "$(t T_ghost '[.HumanParticipated, .LastAuthor] | @csv')" 'true,"(deleted)"'
assert_eq 'more than 100 comments -> Truncated, true count kept' "$(t T_long '[.CommentCount, .Truncated] | @csv')" '150,true'
assert_eq '  the real last comment (a human objection past the first 100) is not missed' "$(t T_long '[.LastAuthor, .AwaitingReply] | @csv')" '"alice",true'
assert_eq '  and an incomplete conversation is conservatively treated as human-touched (escalate)' "$(t T_long '.HumanParticipated')" true
# A long thread whose real last commenter is a deleted account: the visible last comment
# (number 100) is ours, but the real last comment is unknown and must not be replaced by it.
nodes=$(jq -cn --argjson a "$(conv T_long_ghost 150 "$(cm copilot-pull-request-reviewer 'Finding')" "$(cm me-bot 'reply')" | jq -c '.lastComment.nodes = [{author:null,body:"from a deleted account",path:"a.md",line:7,createdAt:"2026-01-02T00:00:00Z"}]')" '[$a]')
page reviewThreads "$nodes" false null >"$FAKE_GH_DIR/threads_first.json"
out2=$("$SCRIPTS/03-list-open-threads.sh" --pr 9 2>&1)
assert_eq 'long thread, last commenter deleted: reported as unknown and awaiting, not as our own reply' "$(jqv "$out2" '.Threads[0] | [.LastAuthor, .AwaitingReply, .HumanParticipated] | @csv')" '"(deleted)",true,true'
assert_eq 'untouched Copilot thread: no replies, awaiting us, no human' "$(t T_fresh '[(.Replies | length), .AwaitingReply, .HumanParticipated, .Truncated] | @csv')" '0,true,false,false'

# ======================================================================
echo "08-reply-and-resolve"
# node_first.json is what 08 reads to see the thread's last comment before replying.
write_node() { # lastAuthor lastBody
  jq -cn --arg a "$1" --arg b "$2" '{data:{node:{comments:{nodes:[{author:{login:$a},body:$b}]}}}}' >"$FAKE_GH_DIR/node_first.json"
}
new_scenario
write_node copilot-pull-request-reviewer 'a finding'
BODYTXT='He said "true" & @file $HOME `x`'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body "$BODYTXT" 2>&1)
assert_eq 'replies then resolves' "$out" $'Replied to thread PRRT_x\nResolved thread PRRT_x'
log=$(cat "$FAKE_GH_DIR/gh.log")
assert_contains 'body goes through -f (plain string, never coerced or read as a file)' "$log" "-f body=$BODYTXT"
assert_not_contains 'never uses -F for the body' "$log" '-F body='
assert_not_contains 'a normal reply carries no hand-off marker' "$log" 'pr-review-loop:handoff'
new_scenario
write_node copilot-pull-request-reviewer 'a finding'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'hi' --no-resolve 2>&1)
assert_eq '--no-resolve only replies' "$out" 'Replied to thread PRRT_x'
assert_contains '--no-resolve appends the hand-off marker' "$(cat "$FAKE_GH_DIR/gh.log")" '<!-- pr-review-loop:handoff -->'
assert_not_contains '  no resolve mutation was sent' "$(cat "$FAKE_GH_DIR/gh.log")" resolveReviewThread
new_scenario
write_node me-bot 'Fixed in abc1234.'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'Fixed in abc1234.' 2>&1)
assert_eq 're-run after a lost response: the identical last reply is not duplicated, but the thread is resolved' "$out" $'Reply already on thread PRRT_x (not posting a duplicate)\nResolved thread PRRT_x'
assert_not_contains '  no reply mutation was sent' "$(cat "$FAKE_GH_DIR/gh.log")" addPullRequestReviewThreadReply
new_scenario
write_node me-bot $'Fixed in abc1234.\n'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'Fixed in abc1234.' 2>&1)
assert_contains '  trailing whitespace differences still count as the same reply' "$out" 'Reply already on thread PRRT_x'
new_scenario
write_node me-bot 'An earlier, different reply'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'Fixed in abc1234.' 2>&1)
assert_contains 'a different reply of ours is still posted' "$out" 'Replied to thread PRRT_x'
new_scenario
write_node someone-else 'Fixed in abc1234.'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'Fixed in abc1234.' 2>&1)
assert_contains "someone else's identical comment is not mistaken for ours" "$out" 'Replied to thread PRRT_x'
new_scenario
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x --body 'hi' 2>&1); rc=$?
assert_eq 'if the pre-reply read fails it stops rather than risk a duplicate' "$rc" 1
assert_not_contains '  and posts nothing' "$(cat "$FAKE_GH_DIR/gh.log")" addPullRequestReviewThreadReply
out=$("$SCRIPTS/08-reply-and-resolve.sh" --thread-id PRRT_x 2>&1 || true)
assert_contains 'requires --body' "$out" '--body is required'
out=$("$SCRIPTS/08-reply-and-resolve.sh" --body hi 2>&1 || true)
assert_contains 'requires --thread-id' "$out" '--thread-id is required'

# ======================================================================
echo "03-review-body"
new_scenario
write_head OPEN $HEAD "$(jq -cn \
  --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-01T00:00:00Z $OLD "old review")" \
  --argjson b "$(review 'copilot-pull-request-reviewer[bot]' COMMENTED 2026-01-02T00:00:00Z $HEAD "$MISSED")" \
  --argjson c "$(review human APPROVED 2026-01-03T00:00:00Z $HEAD 'looks good')" '[$a,$b,$c]')"
out=$("$SCRIPTS/03-review-body.sh" --pr 7 2>&1)
assert_eq 'picks the Copilot review at HEAD (not an older one, not a human review)' "$(jqv "$out" '[.Found, .ReviewAtHead, .CommitOid, .State] | @csv')" 'true,true,"abc123","COMMENTED"'
assert_eq '  includes the body and its Previously-missed count' "$(jqv "$out" '[.PreviouslyMissedCount, (.Body | contains("real finding"))] | @csv')" '1,true'
out=$("$SCRIPTS/03-review-body.sh" --pr 7 --raw 2>&1)
assert_contains '--raw prints just the markdown body' "$out" 'Previously missed (1)'
assert_not_contains '  with no JSON wrapper' "$out" '"PrNumber"'

new_scenario
write_head OPEN $HEAD "$(jq -cn --argjson a "$(review copilot-pull-request-reviewer COMMENTED 2026-01-01T00:00:00Z $OLD 'old only')" '[$a]')"
out=$("$SCRIPTS/03-review-body.sh" --pr 7 2>&1)
assert_eq 'falls back to the newest review when none is at HEAD' "$(jqv "$out" '[.Found, .ReviewAtHead, .Body] | @csv')" 'true,false,"old only"'

new_scenario
write_head OPEN $HEAD '[]'
out=$("$SCRIPTS/03-review-body.sh" --pr 7 2>&1)
assert_eq 'no Copilot review -> Found false, nulls' "$(jqv "$out" '[.Found, .Body, .Url] | tojson')" '[false,null,null]'
out=$("$SCRIPTS/03-review-body.sh" --pr 7 --raw 2>&1)
assert_eq '  --raw prints nothing' "$out" ''

# ======================================================================
echo "09-review-round"
new_scenario
rv() { jq -cn --arg l "$1" '{author:{login:$l}}'; }
pr_comment_node() { jq -cn --arg a "$1" --arg b "$2" '{author:{login:$a},body:$b}'; }
RECAP_BODY=$'Recap: all rounds traced to the PR scope.\n\n<!-- pr-review-loop:recap round=10 -->'
page issueComments '[]' false null >"$FAKE_GH_DIR/comments_first.json"
page reviews "$(jq -cn --argjson a "$(rv copilot-pull-request-reviewer)" --argjson b "$(rv human)" --argjson c "$(rv 'copilot-pull-request-reviewer[bot]')" '[$a,$b,$c]')" true rv1 >"$FAKE_GH_DIR/reviews_first.json"
page reviews "$(jq -cn --argjson a "$(rv copilot-pull-request-reviewer)" '[$a]')" false null >"$FAKE_GH_DIR/reviews_rv1.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'counts Copilot reviews across pages (3, ignoring humans)' "$(jqv "$out" '[.Round, .RecapInterval, .RecapsAcknowledged, .RecapDue] | @csv')" '3,10,0,false'
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --recap-interval 3 2>&1)
assert_eq 'RecapDue when a boundary is reached and not yet acknowledged' "$(jqv "$out" '[.Round, .RecapDue] | @csv')" '3,true'
page reviews '[]' false null >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --recap-interval 1 2>&1)
assert_eq 'Round 0 is never due' "$(jqv "$out" '[.Round, .RecapDue] | @csv')" '0,false'
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --recap-interval 0 2>&1 || true)
assert_contains 'rejects a zero interval' "$out" 'at least 1'

# 9 -> 11: a boundary (10) stepped over by two reviews landing between checks must still be due.
mkreviews() { # n -> reviews page with n Copilot reviews
  jq -cn --argjson n "$1" '{data:{repository:{pullRequest:{reviews:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[range($n) | {author:{login:"copilot-pull-request-reviewer"}}]}}}}}'
}
mkreviews 9 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'round 9: no boundary reached yet' "$(jqv "$out" '[.Round, .RecapDue] | @csv')" '9,false'
mkreviews 11 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'round 11 (jumped from 9 over the boundary at 10): recap is due' "$(jqv "$out" '[.Round, .RecapsAcknowledged, .RecapDue] | @csv')" '11,0,true'
mkreviews 15 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq '  and it stays due on later checks until acknowledged' "$(jqv "$out" '.RecapDue')" true

# Acknowledged: a comment from us with the marker. Others' comments, and ours without it, don't count.
page issueComments "$(jq -cn --argjson a "$(pr_comment_node me-bot "$RECAP_BODY")" --argjson b "$(pr_comment_node alice 'Recap <!-- pr-review-loop:recap round=10 -->')" --argjson c "$(pr_comment_node me-bot 'just a normal comment')" '[$a,$b,$c]')" false null >"$FAKE_GH_DIR/comments_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'one acknowledgement from us clears the boundary at 10 (only ours, only with the marker, counted)' "$(jqv "$out" '[.Round, .RecapsAcknowledged, .RecapDue] | @csv')" '15,1,false'
mkreviews 21 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'the next boundary (20) is due again, relative to the one acknowledgement' "$(jqv "$out" '[.RecapsAcknowledged, .RecapDue] | @csv')" '1,true'

# Comments paginate.
page issueComments "$(jq -cn --argjson a "$(pr_comment_node me-bot 'normal')" '[$a]')" true cm1 >"$FAKE_GH_DIR/comments_first.json"
page issueComments "$(jq -cn --argjson a "$(pr_comment_node me-bot "$RECAP_BODY")" '[$a]')" false null >"$FAKE_GH_DIR/comments_cm1.json"
mkreviews 15 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 2>&1)
assert_eq 'acknowledgements are found across comment pages' "$(jqv "$out" '[.RecapsAcknowledged, .RecapDue] | @csv')" '1,false'

# --ack
page issueComments '[]' false null >"$FAKE_GH_DIR/comments_first.json"
mkreviews 11 >"$FAKE_GH_DIR/reviews_first.json"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --ack --body 'Recap: CONTINUE, every round traces to the PR scope.' 2>&1)
assert_eq '--ack posts the acknowledgement and reports the new state' "$(jqv "$out" '[.Acknowledged, .RecapsAcknowledged, .RecapDue] | @csv')" 'true,1,false'
posted=$(cat "$FAKE_GH_DIR/pr_comment_body.txt")
assert_contains '  the comment carries the recap text' "$posted" 'Recap: CONTINUE, every round traces to the PR scope.'
assert_contains '  and the hidden marker with the round' "$posted" '<!-- pr-review-loop:recap round=11 -->'
assert_contains '  posted with gh pr comment on the right repo' "$(cat "$FAKE_GH_DIR/gh.log")" 'pr comment 5 --repo acme/widgets'

page issueComments "$(jq -cn --argjson a "$(pr_comment_node me-bot "$RECAP_BODY")" '[$a]')" false null >"$FAKE_GH_DIR/comments_first.json"
: >"$FAKE_GH_DIR/gh.log"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --ack --body 'again' 2>&1); rc=$?
assert_eq '--ack when nothing is due fails (cannot be double counted)' "$rc" 1
assert_contains '  and says why' "$out" 'No recap is due'
assert_not_contains '  and posts nothing' "$(cat "$FAKE_GH_DIR/gh.log")" 'pr comment'
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --ack 2>&1 || true)
assert_contains '--ack requires a --body' "$out" '--ack requires a non-empty --body'
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --body hi 2>&1 || true)
assert_contains '--body without --ack is rejected' "$out" '--body is only used with --ack'
page issueComments '[]' false null >"$FAKE_GH_DIR/comments_first.json"
echo 1 >"$FAKE_GH_DIR/pr_comment.exit"
out=$("$SCRIPTS/09-review-round.sh" --pr 5 --ack --body 'recap' 2>&1); rc=$?
assert_eq 'a failed acknowledgement post exits non-zero' "$rc" 1
assert_contains '  and reports the failure' "$out" 'posting the recap acknowledgement failed'

# ======================================================================
echo "10-cleanup-outdated"
new_scenario
cthread() { # id resolved outdated firstAuthor lastAuthor authors_json hasNext cursor [lastBody]
  jq -cn --arg id "$1" --argjson res "$2" --argjson od "$3" --arg fa "$4" --arg la "$5" \
    --argjson au "$6" --argjson hn "$7" --arg cur "$8" --arg lb "${9:-}" '
    def who($l): {author: (if $l == "" then null else {login: $l} end)};
    {id:$id,isResolved:$res,isOutdated:$od,
     firstComment:{nodes:[who($fa)]}, lastComment:{nodes:[who($la) + {body:$lb}]},
     allComments:{totalCount:($au|length),pageInfo:{hasNextPage:$hn,endCursor:$cur},nodes:($au | map(who(.)))}}'
}
COP=copilot-pull-request-reviewer
nodes=$(jq -cn \
  --argjson ok "$(cthread T_ok false true $COP me-bot "[\"$COP\",\"me-bot\"]" false null)" \
  --argjson hum "$(cthread T_human false true $COP me-bot "[\"$COP\",\"alice\",\"me-bot\"]" false null)" \
  --argjson gho "$(cthread T_ghost false true $COP me-bot "[\"$COP\",\"\",\"me-bot\"]" false null)" \
  --argjson aw "$(cthread T_await false true $COP $COP "[\"$COP\"]" false null)" \
  --argjson cur "$(cthread T_current false false $COP me-bot "[\"$COP\",\"me-bot\"]" false null)" \
  --argjson res "$(cthread T_resolved true true $COP me-bot "[\"$COP\",\"me-bot\"]" false null)" \
  --argjson hf "$(cthread T_humanfirst false true alice me-bot "[\"alice\",\"me-bot\"]" false null)" \
  --argjson lng "$(cthread T_long false true $COP me-bot "[\"$COP\",\"me-bot\"]" true n1)" \
  --argjson hoff "$(cthread T_handoff false true $COP me-bot "[\"$COP\",\"me-bot\"]" false null $'Escalating: needs a human.\n\n<!-- pr-review-loop:handoff -->')" \
  --argjson plain "$(cthread T_plain_reply false true $COP me-bot "[\"$COP\",\"me-bot\"]" false null 'Fixed in abc1234.')" \
  '[$ok,$hum,$gho,$aw,$cur,$res,$hf,$lng,$hoff,$plain]')
page reviewThreads "$nodes" false null >"$FAKE_GH_DIR/cleanup_first.json"
jq -cn '{data:{node:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{author:{login:"bob"}}]}}}}' >"$FAKE_GH_DIR/node_n1.json"

out=$("$SCRIPTS/10-cleanup-outdated.sh" --pr 3 --dry-run 2>&1)
assert_contains 'dry run lists the safe thread' "$out" 'Would resolve T_ok (DryRun)'
assert_contains '  a thread whose last reply is a plain fix reply is also a target' "$out" 'Would resolve T_plain_reply (DryRun)'
assert_contains '  and only those two are found' "$out" 'Found 2 outdated Copilot thread(s) to resolve.'
assert_not_contains '  no resolve mutation in a dry run' "$(cat "$FAKE_GH_DIR/gh.log")" resolveReviewThread
assert_contains 'human in thread (incl. on page 2 of comments) skipped x2' "$out" 'Skipped 2 outdated Copilot thread(s) where a non-Copilot'
assert_contains 'ghost author skipped (fail-safe)' "$out" 'Skipped 1 outdated Copilot thread(s) with at least one ghost'
assert_contains 'awaiting reply skipped' "$out" 'Skipped 1 outdated Copilot thread(s) where the last comment is not from'
assert_contains 'hand-off thread (our --no-resolve reply) is left open' "$out" 'Skipped 1 outdated Copilot thread(s) left open as a hand-off'
assert_not_contains '  and is not in the would-resolve list' "$out" 'Would resolve T_handoff'
: >"$FAKE_GH_DIR/gh.log"
out=$("$SCRIPTS/10-cleanup-outdated.sh" --pr 3 2>&1)
assert_contains 'resolves the safe thread' "$out" 'Resolved T_ok'
assert_contains 'summary line' "$out" 'Cleanup summary: resolved=2 failed=0 skippedAwaitingReply=1 skippedHumanInThread=2 skippedUnknownAuthorInThread=1 skippedPaginationError=0 skippedHandoff=1'
assert_eq 'exactly two resolve mutations sent' "$(grep -c 'tid=' "$FAKE_GH_DIR/gh.log")" 2
assert_contains '  for T_ok' "$(cat "$FAKE_GH_DIR/gh.log")" 'tid=T_ok'
assert_not_contains '  never for the hand-off thread' "$(cat "$FAKE_GH_DIR/gh.log")" 'tid=T_handoff'
out=$("$SCRIPTS/10-cleanup-outdated.sh" --pr 3 --force 2>&1)
assert_contains '--force also resolves the awaiting-reply thread' "$out" 'Resolved T_await'
assert_contains '--force does NOT override the human guard' "$out" 'skippedHumanInThread=2'
assert_contains '--force does NOT override the ghost guard' "$out" 'skippedUnknownAuthorInThread=1'
assert_contains '--force does NOT override the hand-off guard' "$out" 'skippedHandoff=1'
assert_not_contains '  (T_handoff still not resolved)' "$out" 'Resolved T_handoff'

echo T_ok >"$FAKE_GH_DIR/resolve_fail_ids"
out=$("$SCRIPTS/10-cleanup-outdated.sh" --pr 3 2>&1); rc=$?
assert_eq 'a failed resolve exits non-zero' "$rc" 1
assert_contains '  and is reported' "$out" 'Failed threads: T_ok'
rm -f "$FAKE_GH_DIR/resolve_fail_ids"

rm -f "$FAKE_GH_DIR/node_n1.json"
out=$("$SCRIPTS/10-cleanup-outdated.sh" --pr 3 2>&1)
assert_contains 'pagination failure on one thread skips it (fail-safe), others proceed' "$out" 'skippedPaginationError=1'
assert_contains '  and the safe thread is still resolved' "$out" 'Resolved T_ok'

# ======================================================================
echo "01-request-review"
mkstate() { # state viewer author requests_json
  jq -cn --arg st "$1" --arg v "$2" --arg au "$3" --argjson rq "$4" '
    {data:{viewer:{login:$v},repository:{pullRequest:{id:"PR_node",headRefOid:"abc123",state:$st,
      author:{login:$au},reviews:{nodes:[]},reviewRequests:{nodes:$rq,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
}
events_txt() { # json_body last_page
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n'
  [ "$2" -le 1 ] || printf 'Link: <https://api.github.com/repositories/1/issues/5/events?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/1/issues/5/events?per_page=100&page=%s>; rel="last"\r\n' "$2"
  printf '\r\n%s\n' "$1"
}
ev() { jq -cn --argjson id "$1" --arg e "$2" --arg t "$3" '{id:$id,event:$e,created_at:$t}'; }

new_scenario
mkstate OPEN me-bot someone "[$(copilot_request)]" >"$FAKE_GH_DIR/state.json"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 2>&1)
assert_eq 'Copilot already requested -> InFlight' "$(jqv "$out" .Status)" InFlight
assert_not_contains '  and no mutation is sent' "$(cat "$FAKE_GH_DIR/gh.log")" requestReviewsByLogin

new_scenario
mkstate MERGED me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 2>&1 || true)
assert_contains 'refuses a PR that is not OPEN' "$out" 'is not OPEN (state=MERGED)'

new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
echo '{"data":{"requestReviewsByLogin":{"pullRequest":{"number":5}}}}' >"$FAKE_GH_DIR/mutation.out"
events_txt "[$(ev 1 labeled 2026-01-01T00:00:00Z)]" 2 >"$FAKE_GH_DIR/events_first.txt"
echo "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z)]" >"$FAKE_GH_DIR/events_page2.json"
echo "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z),$(ev 9 copilot_work_started 2026-01-02T02:00:00Z)]" >"$FAKE_GH_DIR/events_page2_after.json"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 3 2>&1)
assert_eq 'new copilot_work_started event -> TriggerLanded' "$(jqv "$out" .Status)" TriggerLanded
assert_eq '  reports the new event time (read from the LAST page via the Link header)' "$(jqv "$out" .WorkStartedAt)" 2026-01-02T02:00:00Z
assert_contains '  the mutation names the Copilot bot' "$(cat "$FAKE_GH_DIR/gh.log")" 'copilot-pull-request-reviewer'

new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
echo '{"data":{"requestReviewsByLogin":{"pullRequest":{"number":5}}}}' >"$FAKE_GH_DIR/mutation.out"
events_txt "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z)]" 1 >"$FAKE_GH_DIR/events_first.txt"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 1 2>&1 || true)
assert_contains 'no new event within the window -> error, with guidance' "$out" 'no new copilot_work_started event landed within 1 seconds'

# Unparseable events must be an ERROR. Returning "0" would make the baseline "no event yet",
# and a later good read would count an existing event as new: a false TriggerLanded.
new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
echo '{"data":{"requestReviewsByLogin":{"pullRequest":{"number":5}}}}' >"$FAKE_GH_DIR/mutation.out"
events_txt 'this is not json' 1 >"$FAKE_GH_DIR/events_first.txt"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 1 2>&1); rc=$?
assert_eq 'unparseable baseline events -> error, not a silent 0' "$rc" 1
assert_contains '  and says why' "$out" 'unparseable JSON'
assert_not_contains '  the trigger is never sent on a broken baseline' "$(cat "$FAKE_GH_DIR/gh.log")" requestReviewsByLogin

# The newest work-start is entry 100 of page 1 and an unrelated event opened page 2 before we
# looked: the LAST page has no work-start event. Searching only the last page would report
# "no event" for a trigger that landed.
new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
echo '{"data":{"requestReviewsByLogin":{"pullRequest":{"number":5}}}}' >"$FAKE_GH_DIR/mutation.out"
events_txt "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z)]" 2 >"$FAKE_GH_DIR/events_first.txt"
echo "[$(ev 6 labeled 2026-01-01T02:00:00Z)]" >"$FAKE_GH_DIR/events_page2.json"
events_txt "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z),$(ev 9 copilot_work_started 2026-01-02T02:00:00Z)]" 2 >"$FAKE_GH_DIR/events_first_after.txt"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 3 2>&1)
assert_eq 'work-start event NOT on the last events page is still found (searches backward)' "$(jqv "$out" '[.Status, .WorkStartedAt] | @csv')" '"TriggerLanded","2026-01-02T02:00:00Z"'

new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
echo '{"data":{"requestReviewsByLogin":{"pullRequest":{"number":5}}}}' >"$FAKE_GH_DIR/mutation.out"
events_txt '[]' 3 >"$FAKE_GH_DIR/events_first.txt"
echo "[$(ev 7 labeled 2026-01-01T02:00:00Z)]" >"$FAKE_GH_DIR/events_page3.json"
echo "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z)]" >"$FAKE_GH_DIR/events_page2.json"
echo "[$(ev 5 copilot_work_started 2026-01-01T01:00:00Z),$(ev 9 copilot_work_started 2026-01-02T02:00:00Z)]" >"$FAKE_GH_DIR/events_page2_after.json"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 3 2>&1)
assert_eq '  across 3 pages, stopping at the first page (from the end) that has one' "$(jqv "$out" .Status)" TriggerLanded

new_scenario
mkstate OPEN me-bot me-bot '[]' >"$FAKE_GH_DIR/state.json"
events_txt '[]' 1 >"$FAKE_GH_DIR/events_first.txt"
echo 1 >"$FAKE_GH_DIR/mutation.exit"
echo 'GraphQL: viewer does not have the correct permissions to execute RequestReviewsByLogin' >"$FAKE_GH_DIR/mutation.err"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 1 2>&1 || true)
assert_contains 'permission error as the PR author -> author-specific workarounds' "$out" 'You are the PR author (me-bot)'
assert_contains '  mentions the push-a-commit fallback' "$out" 'push a substantive (non-whitespace) commit'

new_scenario
mkstate OPEN me-bot someone-else '[]' >"$FAKE_GH_DIR/state.json"
events_txt '[]' 1 >"$FAKE_GH_DIR/events_first.txt"
echo 1 >"$FAKE_GH_DIR/mutation.exit"
echo 'does not have the correct permissions' >"$FAKE_GH_DIR/mutation.err"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 1 2>&1 || true)
assert_contains 'permission error as a non-author -> generic permission message' "$out" 'failed with a permission error'

new_scenario
mkstate OPEN me-bot someone '[]' >"$FAKE_GH_DIR/state.json"
events_txt '[]' 1 >"$FAKE_GH_DIR/events_first.txt"
echo '{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}],"data":null}' >"$FAKE_GH_DIR/mutation.out"
out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 1 2>&1 || true)
assert_contains 'FORBIDDEN in an exit-0 response body is also a permission error' "$out" 'failed with a permission error'

out=$("$SCRIPTS/01-request-review.sh" --pr 5 --verify-seconds 999 2>&1 || true)
assert_contains 'rejects --verify-seconds out of range' "$out" 'between 1 and 600'

# ======================================================================
echo "oversized payloads (must not hit the argument-length limit)"
# 100 reviews x 20 KB of body ~ 2 MB, past macOS's ~1 MB total argument limit and far past
# Linux's 128 KB per-argument cap. These crashed when big JSON was passed as `jq --argjson`.
BIG=$(head -c 20000 /dev/zero | tr '\0' 'x')
new_scenario
# Build the fixture in ONE jq call (the test helpers pass JSON as arguments, which is the
# very thing under test).
jq -cn --arg b "$BIG" --arg h $HEAD '
  {data:{repository:{pullRequest:{headRefOid:$h,state:"OPEN",reviews:{nodes:
    [range(100) | {author:{login:"copilot-pull-request-reviewer"},state:"COMMENTED",
                   submittedAt:("2026-01-01T00:00:\(. % 60 | tostring | if length < 2 then "0" + . else . end)Z"),
                   body:$b,commit:{oid:$h}}]}}}}}' >"$FAKE_GH_DIR/head.json"
page reviewThreads '[]' false null >"$FAKE_GH_DIR/threads_first.json"
page reviewRequests '[]' false null >"$FAKE_GH_DIR/requests_first.json"
out=$("$SCRIPTS/02-check-review-status.sh" --pr 7 2>/dev/null); rc=$?
assert_eq '02 handles 100 reviews x 20 KB bodies' "$rc" 0
assert_eq '  and still reports the review at HEAD, truncating bodyHead to 300' "$(jqv "$out" '[.ReviewAtHead, (.LatestCopilotReview.bodyHead | length)] | @csv')" 'true,300'

new_scenario
jq -cn --arg b "$BIG" '
  {data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:
    [range(100) | {id:("T\(.)"),isResolved:false,
                   comments:{nodes:[{author:{login:"copilot-pull-request-reviewer"},body:$b,path:"a.md",line:1,createdAt:"2026-01-01T00:00:00Z"}]}}]}}}}}' >"$FAKE_GH_DIR/threads_first.json"
out=$("$SCRIPTS/03-list-open-threads.sh" --pr 7 --max-body-length 0 2>/dev/null); rc=$?
assert_eq '03 lists 100 threads x 20 KB bodies' "$rc" 0
assert_eq '  all 100, bodies intact' "$(jqv "$out" '[.OpenThreadCount, (.Threads[0].Body | length)] | @csv')" '100,20000'

# ======================================================================
echo "00-preflight"
new_scenario
REPO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/prl-repo.XXXXXX")
(
  cd "$REPO_DIR" || exit 1
  git init -q -b main
  git config user.email t@example.com
  git config user.name Tester
  # Throwaway repo: never sign (a developer's global commit.gpgsign=true would otherwise make
  # these commits call gpg, which can prompt, or fail when gpg isn't on PATH).
  git config commit.gpgsign false
  git config tag.gpgsign false
  git commit -q --allow-empty -m init
  git checkout -q -b feature
  git remote add origin https://github.com/acme/widgets.git
)
mkpr() { # state headRefName headOwner
  jq -cn --arg st "$1" --arg hb "$2" --arg ho "$3" '
    {number:5,url:"https://github.com/acme/widgets/pull/5",state:$st,isDraft:false,
     headRefName:$hb,headRefOid:"0000000000000000000000000000000000000000",baseRefName:"main",
     headRepository:{name:"widgets"},headRepositoryOwner:{login:$ho},mergeStateStatus:"CLEAN"}'
}
echo main >"$FAKE_GH_DIR/default_branch"
pre() { (cd "$REPO_DIR" && "$SCRIPTS/00-preflight.sh" --pr 5 2>&1); }

mkpr OPEN feature acme >"$FAKE_GH_DIR/pr.json"
out=$(pre); rc=$?
assert_eq 'matching checkout -> exit 0' "$rc" 0
assert_contains '  prints the verified push command' "$out" 'Push command   git push origin HEAD:refs/heads/feature'
fetchlog=$(cat "$FAKE_GH_DIR/git-fetch.log" 2>/dev/null)
assert_contains '  fetches with credential prompts disabled (cannot hang waiting for input)' "$fetchlog" 'prompt=0'
assert_contains '  with ssh in batch mode' "$fetchlog" 'ssh -o BatchMode=yes'
assert_contains '  and aborts stalled transfers' "$fetchlog" 'http.lowSpeedLimit=1000'

(cd "$REPO_DIR" && git checkout -q -b other)
out=$(pre); rc=$?
assert_eq 'wrong branch checked out -> exit 1' "$rc" 1
assert_contains '  says what to run' "$out" "checked out 'other' but PR head is 'feature' -- run: gh pr checkout 5"
(cd "$REPO_DIR" && git checkout -q feature)

mkpr OPEN feature fork-owner >"$FAKE_GH_DIR/pr.json"
out=$(pre); rc=$?
assert_eq 'fork PR with no matching remote -> exit 1' "$rc" 1
assert_contains '  names the missing remote' "$out" 'no local remote points at fork-owner/widgets'
(cd "$REPO_DIR" && git remote add fork https://github.com/fork-owner/widgets.git)
out=$(pre); rc=$?
assert_eq '  adding the fork remote -> exit 0' "$rc" 0
assert_contains '  pushes to the fork remote, not origin' "$out" 'Push command   git push fork HEAD:refs/heads/feature'
(cd "$REPO_DIR" && git remote remove fork)

mkpr MERGED feature acme >"$FAKE_GH_DIR/pr.json"
out=$(pre); rc=$?
assert_eq 'merged PR -> exit 1' "$rc" 1
assert_contains '  says so' "$out" 'PR is MERGED, not OPEN'

(cd "$REPO_DIR" && git checkout -q main)
mkpr OPEN main acme >"$FAKE_GH_DIR/pr.json"
out=$(pre); rc=$?
assert_eq 'PR head is the default branch -> exit 1' "$rc" 1
assert_contains '  refuses to push there' "$out" 'PR head is the default branch'
rm -rf "$REPO_DIR"

# ======================================================================
echo "all scripts: a flag with no value is rejected (never hangs)"
# Run in the background with a hard deadline: the bug being guarded against is an endless loop.
run_guarded() { # cmd... -> sets GUARD_OUT / GUARD_RC; GUARD_RC=hung if it didn't exit in 5 s
  local outf; outf=$(mktemp "${TMPDIR:-/tmp}/prl-guard.XXXXXX")
  "$@" >"$outf" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; GUARD_RC=hung; else wait "$pid"; GUARD_RC=$?; fi
  GUARD_OUT=$(cat "$outf"); rm -f "$outf"
}
new_scenario
for pair in 00-preflight:--pr 00-preflight:--owner 00-preflight:--repo \
  01-request-review:--pr 01-request-review:--owner 01-request-review:--repo 01-request-review:--verify-seconds \
  02-check-review-status:--pr 02-check-review-status:--owner 02-check-review-status:--repo \
  03-list-open-threads:--pr 03-list-open-threads:--owner 03-list-open-threads:--repo 03-list-open-threads:--max-body-length \
  03-review-body:--pr 03-review-body:--owner 03-review-body:--repo \
  08-reply-and-resolve:--thread-id 08-reply-and-resolve:--body \
  09-review-round:--pr 09-review-round:--owner 09-review-round:--repo 09-review-round:--recap-interval 09-review-round:--body \
  10-cleanup-outdated:--pr 10-cleanup-outdated:--owner 10-cleanup-outdated:--repo; do
  script=${pair%%:*} flag=${pair#*:}
  run_guarded "$SCRIPTS/$script.sh" "$flag"
  assert_eq "$script $flag with no value exits (no hang)" "$GUARD_RC" 1
  assert_contains "  and says it needs a value" "$GUARD_OUT" "$flag requires a value"
done

# ======================================================================
echo "all scripts: --help and unknown arguments"
for s in 00-preflight 01-request-review 02-check-review-status 03-list-open-threads 03-review-body 08-reply-and-resolve 09-review-round 10-cleanup-outdated; do
  out=$("$SCRIPTS/$s.sh" --help 2>&1)
  assert_contains "$s --help prints usage" "$out" 'Usage:'
  out=$("$SCRIPTS/$s.sh" --bogus 2>&1 || true)
  assert_contains "$s rejects unknown arguments" "$out" 'unknown argument: --bogus'
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
