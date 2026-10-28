# Step 9: Convergence verify

Owner: **delegable** to an `inspect`-class worker; budget: 3 min.
See [harness-adaptation.md](harness-adaptation.md).

## Inputs

- `PrNumber`.
- The pushed `HeadOid` from step 7 (for the independent sanity check).
- Whether the loop is in normal mode or [single-iteration
  mode](orchestration.md#single-iteration-fallback) (decided at step 1).

## Return contract

```
{ converged, head_oid, latest_review_commit_oid, submitted_at,
  open_thread_count, open_threads_awaiting_reply, escalated_threads }
```

`converged` is the single source-of-truth boolean — `Converged: true`
returned by `02-check-review-status.sh`.

## Procedure

Run the status check, passing `--single-iteration` iff the loop took the
fallback at step 1:

```bash
./scripts/02-check-review-status.sh --pr <n>
# single-iteration variant:
./scripts/02-check-review-status.sh --pr <n> --single-iteration
```

Then run an **independent HEAD-vs-`LatestCopilotReview.commitOid`
sanity check** — the orchestrator's recorded `HeadOid` from step 7 should
match `HEAD` and (in normal mode) match the latest review's
`commitOid`.

## Decision: loop back or exit

After the status check, the orchestrator agent **must** branch on `converged`:

```
if converged == true:
    run step 10 once (cleanup outdated)
    run step 11 once (squash message: commit-message skill on the PR diff, shown as markdown)
    report completion with proof (HeadOid, LatestCopilotReview.commitOid, submittedAt),
      any human hand-offs (ReviewSummary), and the squash message
    DONE — exit the loop
else:
    # non-converged = a fresh Copilot finding OR an unresolved human thread.
    # round = count of Copilot review submissions in the PR's history,
    #         read deterministically from the API (NOT a mental tally):
    #             ./scripts/09-review-round.sh --pr <n>   -> {Round, RecapsAcknowledged, RecapDue}
    if RecapDue == true:                        # a boundary (10, 20, 30, ...) was reached
        RUN THE RECAP GATE (see "Round cap & recap gate" below) BEFORE looping:
            recap ALL prior rounds, then pick CONTINUE / REVERT-AND-SHIP / HAND-OFF,
            and record it:  ./scripts/09-review-round.sh --pr <n> --ack --body "<the recap>"
            CONTINUE        -> fall through and start another round
            REVERT-AND-SHIP -> drop drifted commits, ship the in-scope result, exit
            HAND-OFF        -> escalate to the user with the recap, exit
    GO BACK TO STEP 1 — start another round
    (re-trigger via 01-request-review.sh, wait via 02-wait,
     list via 03-list-threads, triage, fix, push, reply+resolve,
     re-check via this step)
```

A non-converged result is **never** terminal *on its own* — each round
addresses the open review feedback on the previous round's HEAD,
whether that's a **Copilot finding or a human review comment** (this
skill handles both). The loop terminates only when there are **no new
review comments from either source** AND **every open thread — Copilot
or human — has a reply from the agent** (a thread the agent escalated
to the user counts as replied; it stays open in `OpenThreadCount` as an
explicit hand-off, not as loop work). But "never terminal" must not be
read as "infinite": a bot-review loop has no guaranteed fixed point and
can drift into over-engineering or oscillation. No script *enforces* a
cap or stops the loop — capping is a reasoning decision the orchestrator owns
at the [round-cap recap gate](#round-cap--recap-gate-circuit-breaker)
below. What *is* scripted is the round **count** itself
([09-review-round.sh](#round-cap--recap-gate-circuit-breaker)), so the
gate's trigger is deterministic rather than a fallible mental tally
(and oscillation — the same finding re-raised across rounds — is
broken earlier per
[04-triage.md](04-triage.md#conflicting-comments--break-oscillation-early)).

`--single-iteration` mode is the **one** exception: by definition, it
runs one round only (the trigger path is unavailable), and the
`converged` result is taken as terminal whichever way it goes.

### Convergence semantics

`02-check-review-status.sh` implements a PR-state guard plus three Converged branches (see the `Converged:` expression in the final `jq` program of that script for the canonical source):

- **PR State guard (overrides everything)** — if `State != 'OPEN'` (CLOSED / MERGED), `Converged: false` regardless of all other flags. The agent cannot push to a non-OPEN PR; surface the state change to the user and abort the loop rather than reporting completion.
- **Normal (Copilot-driven) mode** — a Copilot review exists OR `CopilotPending: true`:
  `Converged: true` iff
  `ReviewAtHead && NoNewComments && OpenThreadsAwaitingReply == 0 && !CopilotPending`
  (a clean review at HEAD does not end the loop while another review of the same HEAD is
  still in flight; it may yet post findings).
  `NoNewComments` is true only for a clean review body: `**0 open findings**`
  (current format) or "generated no new comments" (older format), **and** no
  "Previously missed" section. Findings listed there are unthreaded, so a review
  with `PreviouslyMissedCount > 0` is not converged; see
  [03-list-threads.md](03-list-threads.md).
- **Single-iteration mode** (`--single-iteration` passed because the loop took the [fallback at step 1](orchestration.md#single-iteration-fallback)):
  `Converged: true` iff `OpenThreadsAwaitingReply == 0`. The stale-review checks can never advance without a new Copilot review, so they're omitted.
- **No Copilot review ever observed AND not pending** (brand-new PRs with zero findings, or PRs where the trigger silently failed and the script wasn't called with `--single-iteration`):
  `Converged: true` iff `OpenThreadsAwaitingReply == 0`. **Do NOT trust this as "loop done" before step 1 has fired** — it just means there's no human-thread work pending. The orchestrator agent MUST run `01-request-review.sh` first (per [step 1](01-request-review.md)) and re-check; treating brand-new-PR convergence as terminal will short-circuit the entire loop.

**The snapshot is consistent or it fails.** `02-check-review-status.sh` reads everything that
feeds `Converged` twice (the PR head and the contents of the reviews, every page of threads,
every page of review requests) and compares the two passes. If anything moved (a commit,
a review, a human reply, a new Copilot request), it retakes the snapshot, so it cannot combine
an old clean review with a newer pending one or miss a reply that landed after the threads were
read. If the PR keeps changing for 3 attempts it exits non-zero rather than guess. Re-run it
after a moment; do not treat that failure as convergence.

**`Converged` is about the agent, not the humans.** It can be `true` while Copilot's
header says "Needs a closer look" and asks a person to confirm something (e.g. production
preflight checks, staging validation) with 0 findings. That is a hand-off, not agent work,
so it does not block convergence. But it must not vanish: read `ReviewVerdict` and
`ReviewSummary` from the status output, and when the verdict is not "Approved", put
`ReviewSummary` verbatim in the completion message as an item for the human merge owner.

`OpenThreadCount` MAY be `> 0` when escalated-to-user threads stay
open — that's an explicit human hand-off, not a loop failure. Return
the list of escalated `thread_id`s so the orchestrator can include them in
the convergence proof.

## Round cap & recap gate (circuit breaker)

No script *enforces* a max-rounds cap or stops the loop — a hard number
can't tell a *productive* round from a *drifting* one. Instead the orchestrator
agent runs a **recap gate** as reasoning: default **STOP at every 10th
round** (10, 20, 30, …) **before** looping back to step 1, recap all
prior rounds, and decide whether the loop is still serving the PR's
original scope.

What *is* scripted is the **count**, so the gate's trigger is
deterministic instead of a fallible mental tally. A **round** is **one
execution of [step 1](01-request-review.md)** — one Copilot-review
trigger at the top of the loop — which produces at least one Copilot
review submission. [`09-review-round.sh`](../scripts/09-review-round.sh)
counts those submissions straight from the PR's API history and reports
whether a recap is due:

```bash
./scripts/09-review-round.sh --pr <n>
# {"PrNumber":<n>,...,"Round":20,"RecapInterval":10,"RecapsAcknowledged":1,"RecapDue":true}
```

**Due means "a boundary was reached and nobody has acknowledged it", not "the count is exactly a
multiple of 10".** `RecapDue` is true when `floor(Round / RecapInterval)` exceeds
`RecapsAcknowledged`. An automatic review on push plus a requested one can land two reviews
between checks and take the count from 9 to 11, stepping over 10; an exact-multiple test would
miss that, and with two reviews per round it could skip every boundary. This way the recap stays
due until the orchestrator acknowledges it.

**Acknowledging.** After running the recap and picking a verdict, record it **before looping
back** (and before a REVERT-AND-SHIP or HAND-OFF exit, so the record exists):

```bash
./scripts/09-review-round.sh --pr <n> --ack --body "<the recap: what the rounds were, drift assessment, verdict>"
```

That posts `--body` as a PR comment carrying a hidden marker. The acknowledgement is derived from
the PR (comments by the authenticated user with that marker), so no state lives outside it, and
the recap is a visible record for the human merge owner. `--ack` fails when no recap is due, so
it can't be double-counted.

Run `09-review-round.sh` at the top of the non-converged branch and gate on `RecapDue`.
Because the count is **derived from history, not remembered**, it can't
drift even across a 100+ round run — the exact failure this gate exists
to catch. The cap counts **review rounds** (Copilot review submissions),
not worker calls, tool calls, or individual fix edits — so a round
that triages five threads still counts as one. The cadence is the
`--recap-interval` knob (default 10). The script reports the trigger only;
it never decides the verdict.

This exists because an unbounded bot-review loop is the failure mode
this skill was built to survive: a real run drifted for 156 rounds —
later rounds "fixing" things the PR never set out to change, eventually
reverting their own earlier fixes. The gate catches that class of drift
early, every 10 rounds, instead of once at the end.

### What the recap reviews (ALL prior rounds, not just the last 10)

1. **Original PR scope** — the issue/PR title and the diff at the PR's
   base. This is the yardstick; everything else is measured against it.
2. **Per-round ledger** — for each round so far: the Copilot finding,
   the disposition (fixed / declined / escalated), and the resulting
   change (files + intent in one line).
3. **Drift signals** across the whole history:
   - **Out-of-scope** — a change that doesn't trace back to the
     original issue/PR goal (new feature, adjacent refactor, polish
     the PR never promised).
   - **Over-engineering** — defensive layers, abstractions, or config
     added solely to satisfy bot nits, not the PR's actual goal.
   - **Wrong-direction** — a fix that later rounds had to undo, work
     around, or re-fix (self-revert / oscillation across rounds).
   - **Belongs-in-separate-PR** — a legitimate improvement that is
     nonetheless unrelated to this PR's stated change.
   - **Scope/complexity growth** — diff size or file count climbing
     while the original goal was met rounds ago.

### Verdicts

| Verdict | When | Action |
| --- | --- | --- |
| **CONTINUE** | Every round so far traces to the original PR scope; no drift signals; Copilot is still surfacing in-scope findings. | Loop back to step 1 for the next 10-round block. |
| **REVERT-AND-SHIP** | One or more rounds drifted (over-engineering / wrong-direction / oscillation) but the in-scope fixes are sound. | `git revert` (or drop) only the drifted commits, keep the in-scope ones, run step 6 build/test, then ship the clean result. Record which rounds were reverted in the convergence proof. |
| **HAND-OFF** | Drift is entangled with in-scope work, the right fix is a redesign, or the change belongs in a separate PR. | Stop the loop, reply on the relevant threads, and escalate to the user with the recap and a recommendation (separate PR / redesign). Do **not** keep looping. |

The **trigger** is scripted but the **verdict** is agent reasoning —
deliberately. [`09-review-round.sh`](../scripts/09-review-round.sh)
makes the *count* deterministic (so the gate can't be missed), but
*which verdict to pick* stays a judgment call: no number can tell a
productive round from a drifting one. The recap is cheap (read the
per-round commits + the PR base diff); the cost of *skipping* it is
another runaway loop.



- **Trust `02-check-review-status.sh`'s `Converged` flag, not your
  own re-derivation.** The script enforces all three conditions
  (normal mode) or the simplified condition (single-iteration) and
  is the canonical source.
- **Do not report completion until `converged == true`.** Print
  the proof (`HeadOid`, `LatestCopilotReview.commitOid`,
  `submittedAt`, `OpenThreadsAwaitingReply: 0`, list of escalated
  threads if `OpenThreadCount > 0`) in the completion message.
- **`--single-iteration` is sticky to the fallback decision.** If
  step 1 took the fallback, every step 9 in this loop uses
  `--single-iteration`; don't flip it mid-loop.
- **PR State != OPEN aborts the loop.** If `State` is `CLOSED` or
  `MERGED`, `Converged` is forced `false` by the script's state
  guard. The orchestrator agent cannot push to a non-OPEN PR — surface
  the state change to the user and stop the loop rather than
  retrying or reporting completion.
