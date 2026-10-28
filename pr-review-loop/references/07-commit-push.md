# Step 7: Commit and push

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a.

## Inputs

- The fix results from step 5 and the green build from step 6.
- The `Push command` printed by step 0 ([00-preflight.md](00-preflight.md)).

## Return contract

- Pushed `HeadOid` (the new commit SHA), recorded for step 8 reply
  bodies and step 9 convergence proof.

## Procedure

- If the checkout may have changed since step 0 (branch switched, rebased,
  pulled), re-run `./scripts/00-preflight.sh --pr <n>` first and stop on any
  `STOP`.
- Orchestrator runs `git commit`, then pushes with the **exact `Push command` from
  preflight** (e.g. `git push <remote> HEAD:refs/heads/<head-branch>`). Never
  a bare `git push`: that publishes to whatever the current branch tracks,
  which is the wrong place if the wrong branch is checked out, and it is the
  wrong remote for a fork PR. One focused commit per round — bundling rounds
  destroys the audit trail of which finding drove which change and breaks
  `git bisect`.
- Amend only when preflight reports `yours yes`, `parents 1`, and the commit is
  not yet pushed; otherwise make a new commit.
- Include the trailer:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
- Record the pushed SHA so step 8 can cite it in every reply body and
  step 9 can compare it against `LatestCopilotReview.commitOid`.

## An unchanged round (nothing to commit)

A round where step 5 produced **no edits** is normal: every finding was declined or
escalated, or the review came back clean. There is nothing to commit, and `git commit` would
fail. So:

- **Don't create an empty commit** (or a whitespace edit) just to advance the workflow. It
  would add noise to the history and, worse, re-trigger Copilot for no reason.
- Skip the commit. If there are already-committed but **unpublished** commits (preflight's
  `pushed` is `no`, or `ahead` is above 0), push them with preflight's `Push command`.
  Otherwise there is nothing to push.
- The `HeadOid` for steps 8 and 9 is the **currently published HEAD**: take it from
  `./scripts/00-preflight.sh --pr <n>` (`PR head oid`) or `git rev-parse HEAD` once it is
  confirmed pushed. A decline or escalation reply doesn't need to cite a fix SHA, but if it
  names one, use this.
- Step 9 still runs, and still needs a Copilot review at the published HEAD: an unchanged
  HEAD means the existing review is already at HEAD, so the convergence check can pass
  without re-requesting one.
