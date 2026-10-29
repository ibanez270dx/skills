---
name: pr-review-loop
description: >-
  Address GitHub pull request feedback through repeated Copilot code review
  rounds. Use when asked to run a Copilot review loop, address Copilot
  comments, or iterate on Copilot feedback. Triage findings, validate fixes,
  and verify review convergence at the current HEAD.
compatibility: >-
  Requires git, GitHub CLI (gh), jq, Bash 3.2+, and authenticated network
  access to GitHub. Windows requires WSL or Git Bash. Full review loops
  require access to request Copilot reviews on the target repository.
metadata:
  author: jeff@humani.se
  version: "1.0"
---

# Copilot PR Review Loop

Drive a GitHub PR through Copilot review, triage, fixes, validation, and
re-review. Optimize for correct, in-scope changes rather than accepting
every suggestion. Keep a written disposition for each finding and finish
with evidence that Copilot reviewed the published HEAD.

## Scope and operating mode

Choose the mode from the user's request before doing remote work:

- **Request only:** request Copilot review and report whether the trigger
  landed or a review was already pending. Do not proceed to fixes, commits,
  pushes, or review replies unless the user asked for those actions.
- **Full loop:** address Copilot feedback, validate changes, push fixes,
  reply, and re-request review until convergence or an explicit stopping
  condition. A request to run the review loop authorizes those normal steps.
- **Limited pass:** if review cannot be requested because Copilot is
  unavailable or permissions are insufficient, address existing Copilot
  feedback once within the user's scope. Report that fresh review remains
  unavailable; this is not verified Copilot convergence.

Human and other-bot threads are visible to the loop but default to human
hand-offs. Do not silently expand into a general review workflow. Merging,
deployment, force-pushing, and unrelated refactors require separate scope.

## Execution setup

Read the target repository's instructions and verify the PR, checkout, and
branch before edits or pushes. Keep that repository as the working directory.
Resolve this installed skill's absolute directory as `skill_dir`, then call
its scripts by absolute path, for example:

```bash
"$skill_dir/scripts/02-check-review-status.sh" --pr <n>
```

References use `./scripts/...` as shorthand for that invocation; do not
change into this skill's source checkout to run a target-project workflow.
Pass both `--owner` and `--repo` when overriding repository detection.

Scripts report missing tools and authentication errors. Surface these and
stop until resolved. Review triggering uses GraphQL, not an `@copilot`
mention. Read [01-request-review.md](references/01-request-review.md) for
trigger handling and [api-quirks.md](references/api-quirks.md) before changing
API scripts.

Single-agent execution is the baseline. Delegate bounded analysis or fixes
only when supported and permitted; keep remote mutations and the completion
decision with the coordinating agent. Read
[harness-adaptation.md](references/harness-adaptation.md) if adapting
execution or using workers. No worker is needed just to wait.

## Workflow

Read each step's contract when it becomes relevant. Cross-round state,
stopping conditions, and limited-pass behavior live in
[orchestration.md](references/orchestration.md).

| Step | Action | Contract |
| --- | --- | --- |
| 0 | Verify checkout and record the exact push command. | [Preflight](references/00-preflight.md) |
| 1 | Capture the review baseline; request review unless already pending. Request-only mode ends here. | [Request](references/01-request-review.md) |
| 2 | Run the read-only wait script; stop on timeout or error. | [Wait](references/02-wait.md) |
| 3 | Read unresolved threads and review-body findings. | [Findings](references/03-list-threads.md) |
| 4 | Decide fix, decline with rationale, or escalate. | [Triage](references/04-triage.md) |
| 5 | Apply focused fixes following project conventions. | [Fix](references/05-fix.md) |
| 6 | Run the repository's required build, test, and lint checks. | [Validation](references/06-build-test.md) |
| 7 | Commit actual fixes and push using preflight's verified command. | [Commit and push](references/07-commit-push.md) |
| 8 | Reply with the disposition; cite published SHAs for fixes. | [Reply and resolve](references/08-reply-resolve.md) |
| 9 | Verify current-HEAD convergence; check for drift before another round. | [Convergence](references/09-convergence.md) |
| 10 | Clean up eligible outdated threads once after convergence. | [Cleanup](references/10-cleanup.md) |
| 11 | Produce a squash message from the final PR diff. | [Squash message](references/11-squash-message.md) |

In full-loop mode, repeat steps 1–9 while actionable work remains and the
loop is making in-scope progress. Run steps 10–11 only after verified
convergence. In limited-pass mode, skip request/wait and process existing
feedback once; use the distinct completion status below.

## Essential safeguards

- **Read review bodies as well as threads.** `PreviouslyMissedCount > 0`
  identifies unthreaded findings; use `03-review-body.sh` and disposition
  them explicitly. Zero unresolved threads alone does not prove convergence.
- **Reply before resolving.** Resolve loop-owned fix/decline threads only.
  Escalations use `08-reply-and-resolve.sh --no-resolve` and remain open.
  Human participation makes a thread a hand-off unless explicitly scoped in.
- **Validate before pushing.** Preserve unrelated local work and use only
  the preflight's push command. Skip committing when no actual edits exist.
- **Never manufacture a commit to trigger review.** A wait timeout is a
  stopped outcome, not an instruction to edit code, push, or re-request.
  Genuine unpublished fixes may be pushed within the authorized workflow.
- **Check for drift and oscillation.** `09-review-round.sh` reports review
  counts and `RecapDue`. At a recap boundary, assess all prior rounds against
  the original scope before continuing. Stop earlier for repeated reversals
  or lack of progress. Reverts need fresh validation and review too.

## Completion evidence

Report the actual outcome: **review requested**, **Copilot converged at
HEAD**, **existing feedback addressed; fresh review unavailable**, or
**stopped** with the reason and next action.

For full-loop success, require a real Copilot review at the published HEAD
and the normal-mode `02-check-review-status.sh` result `Converged: true`.
Never substitute a limited-pass result or the no-review-yet branch for that
evidence. Include `HeadOid`, `LatestCopilotReview.commitOid`, `submittedAt`,
and `OpenThreadsAwaitingReply: 0`. Surface open escalations and any human
confirmation requested by `ReviewVerdict` / `ReviewSummary`. Provide the
squash message in a fenced `markdown` block; the squash step includes a
fallback when the optional `commit-message` skill is not installed.
