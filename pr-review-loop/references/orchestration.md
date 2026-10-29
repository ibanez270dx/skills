# Loop control and outcomes

The entry point owns the step order. This reference defines cross-round
state and stopping behavior. Single-agent execution is sufficient; see
[harness-adaptation.md](harness-adaptation.md) for optional delegation.

## State to retain

- Target repository, PR number, original scope, and selected operating mode.
- Preflight's branch, head repository, and verified push command.
- Published HEAD, review baseline, and latest review evidence.
- Findings (including review-body items), dispositions, replies, and hand-offs.
- Per-round changes and validation results, plus any unpublished work.

After interruption, re-read the PR status, checkout, and working tree.
Invalidate cached drafts or triage when their underlying code or conversation
changed. Preserve unrelated local changes; never sweep them into a loop commit.

## Request-only mode

Capture the baseline and run step 1. Report the target HEAD and whether the
request landed or was already pending. A failed request is a failed request,
not an invitation to edit or push. End without entering the repair loop.

## Full loop

Request → wait → list → triage → fix → validate → commit/push →
reply/resolve → verify. Skip committing if there are no edits. Replies to
fixes cite the published SHA. Reuse an in-flight review rather than adding
another request. Waiting is handled by the shell script, not a model worker.

If step 9 is not converged, check `09-review-round.sh` and run the recap
when `RecapDue` is true before starting another round. Stop earlier for
oscillation, out-of-scope changes, or repeated inability to make progress.
See [09-convergence.md](09-convergence.md#round-cap--recap-gate-circuit-breaker).

## Single-iteration fallback

Use a limited pass only after identifying a concrete reason review cannot
be requested: Copilot unavailable on the target, or insufficient permission.
Do not infer unavailability from a slow review, transient error, or an
unverified trigger. An unknown trigger outcome needs inspection before retry.

Within the authorized repair scope, handle existing Copilot findings once
using steps 3–8, including body-only findings. Preserve the reviewer-type
policy for human and other-bot threads. Step 9 may use `--single-iteration`
to check reply coverage, but its `Converged` flag does **not** establish
fresh Copilot review. Do not claim full convergence or run the normal
post-convergence cleanup based on that flag. Report addressed work, anything
remaining, and how a maintainer can request review. A request-only task does
not become a limited repair pass automatically.

## Stopping conditions

| Condition | Outcome and next action |
| --- | --- |
| Fresh clean Copilot review at published HEAD and normal-mode `Converged: true` | Run cleanup and produce the final squash message; report convergence with evidence. |
| Request-only trigger landed or was already pending | Report review requested/pending; do not claim convergence. |
| Limited pass finished | Report existing feedback addressed and fresh review unavailable; list remaining items. |
| Wait deadline expired | Report stopped: review timed out, latest HEAD/review/pending state, and how to resume waiting. Do not create a trigger commit. |
| PR closed/merged or HEAD changed unexpectedly | Stop, inspect changed state, and revalidate before any further mutations. |
| Tools, auth, permissions, validation, or API failure blocks progress | Preserve work and report the concrete blocker. Do not treat it as successful review. |
| Drift or oscillation needs human judgment | Stop with a recap and recommendation; do not merge or declare convergence. |

A necessary in-scope fix can be committed and pushed normally; a new commit
solely to stimulate Copilot is never a recovery action. Manual review
re-request may be needed when API permissions are missing. Never rewrite
published history or merge/deploy as part of timeout or drift recovery.
