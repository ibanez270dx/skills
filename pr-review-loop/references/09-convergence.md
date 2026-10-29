# Step 9: Verify convergence

Owner: orchestrator decides completion; read-only inspection may be delegated.
Run from the target repository using the installed skill's script paths.

## Evidence and decision

```bash
./scripts/02-check-review-status.sh --pr <n>
```

For full-loop success, require all of the following from the normal-mode
snapshot, and independently compare the published SHA with local HEAD and
the SHA recorded at step 7:

- PR is `OPEN` and a real `LatestCopilotReview` exists.
- `HeadOid` equals `LatestCopilotReview.commitOid` (`ReviewAtHead: true`).
- `NoNewComments: true` and `PreviouslyMissedCount: 0`.
- `OpenThreadsAwaitingReply: 0` and `CopilotPending: false`.
- `Converged: true` from the canonical status checker.

The status script owns parsing and snapshot consistency. Do not replace it
with a thread count or a separate interpretation of the review body.

If these conditions hold, run steps 10 and 11 once, then report **Copilot
converged at HEAD** with `HeadOid`, `LatestCopilotReview.commitOid`,
`submittedAt`, and `OpenThreadsAwaitingReply: 0`. List open human hand-offs.
When `ReviewVerdict` is not `Approved`, include `ReviewSummary` verbatim
when present: a clean review may still request human confirmation.

If not converged, inspect why. New or remaining findings lead to another
round after the recap check below. An in-flight review leads to bounded
waiting, not another trigger. Timeout, PR closure, unexpected HEAD changes,
failed validation, API failures, or drift lead to the explicit stopped
outcomes in [orchestration.md](orchestration.md#stopping-conditions).

## Convergence semantics

The canonical script has several branches. Their output is useful only
with the selected operating mode:

| Branch | Meaning |
| --- | --- |
| PR not open | `Converged: false`; stop rather than pushing or looping. |
| Copilot review exists or is pending | Convergence requires a clean at-HEAD review, no pending review, and no threads awaiting reply. |
| `--single-iteration` | `Converged` checks reply coverage only. Report limited-pass completion, never fresh Copilot convergence. |
| No Copilot review and none pending | `Converged` can be true with zero unanswered threads. This is not Copilot convergence: step 1 must request review, or report a concrete inability to do so. |

In a limited pass, use `--single-iteration` only after the fallback decision
at step 1. Handle body-only findings too; reply coverage alone cannot prove
they were addressed. End after that pass with the addressed and remaining
work, and state that fresh review is unavailable. Do not run post-convergence
cleanup or claim full-loop success from this branch.

Open threads may remain when each is an explicit escalation with our reply.
A human replying later puts that thread back into triage. Non-Copilot threads
default to hand-offs unless the user scoped them in; they do not turn this
into a general review workflow.

The script takes two reads of all convergence inputs: HEAD/reviews, all
thread pages, and all review-request pages. If they differ, it retries the
snapshot, failing after three unstable attempts rather than combining
inconsistent state. An error is not convergence. Review bodies with
Previously missed findings are never clean, even if they show zero new
threaded findings; read `03-review-body.sh` as described in step 3.

## Round cap & recap gate (circuit breaker)

Before starting another non-converged round, run:

```bash
./scripts/09-review-round.sh --pr <n>
```

The script counts Copilot review submissions from PR history, including
automatic reviews. This is a review-count proxy for rounds, not a count of
agent invocations or triggers. Its default recap interval is 10; `RecapDue`
stays true after crossing a boundary until acknowledged, so concurrent
reviews cannot skip the gate by jumping from 9 to 11.

When due, recap **all** prior rounds against the original PR scope:

1. Original goal and the changes actually required to achieve it.
2. Each finding, fix/decline/escalation disposition, and resulting change.
3. Out-of-scope growth, speculative abstractions, reversals of earlier fixes,
   repeated findings without progress, and work belonging in a separate PR.

Stop earlier for oscillation; do not wait for a multiple of 10 when about
to repeat an edit already reverted. See
[04-triage.md](04-triage.md#conflicting-comments--break-oscillation-early).

Choose and record the verdict:

| Verdict | Action |
| --- | --- |
| `CONTINUE` | Findings and changes remain in scope and productive. Start the next round. |
| `REVERT-AND-REVIEW` | Clearly isolated drift can be safely undone within scope. Preserve in-scope work, create ordinary revert commits without rewriting published history, validate, push, and obtain fresh review of the resulting HEAD. If selecting the reverts needs human judgment, hand off instead. |
| `HAND-OFF` | Drift is entangled, fixes oscillate, or a redesign needs a decision. Stop with a recap and recommendation; do not claim convergence. |

```bash
./scripts/09-review-round.sh --pr <n> --ack --body "<recap and verdict>"
```

Acknowledgement posts a visible PR comment with a hidden marker; keep it
with the orchestrator's other remote mutations. A recap is not a successful
review, and a revert invalidates prior HEAD evidence. No verdict authorizes
merging, deployment, or a force-push. Only fresh convergence can end the
full loop successfully; a hand-off is a separate stopped outcome.
