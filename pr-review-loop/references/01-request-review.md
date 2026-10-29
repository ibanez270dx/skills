# Step 1: Request review

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a.

## Inputs

- `PrNumber` for the target PR.

## Return contract

- Captured `baseline` = `LatestCopilotReview.submittedAt` string (or empty)
  to be passed to step 2.
- Expected published `HeadOid` for the wait script.
- Boolean `single_iteration_mode` — true only after identifying Copilot
  unavailability or insufficient review-request permission in repair mode.

## Procedure

1. Snapshot first to learn whether Copilot is already pending:

   ```bash
   snap=$(./scripts/02-check-review-status.sh --pr <n>)
   baseline=$(printf '%s' "$snap" | grep -o '"submittedAt":"[^"]*"' | head -1 | cut -d'"' -f4)
   case $snap in *'"CopilotPending":true'*) pending=1 ;; *) pending=0 ;; esac
   ```

   The output is one line of compact JSON, so matching the raw text is
   enough (or pipe to `jq`). Keep `submittedAt` as the plain string
   GitHub sent so baseline comparisons stay lexicographic.

2. Record `HeadOid` from the snapshot. **If `pending`**, skip the trigger;
   in repair mode jump to step 2 with `baseline` and the expected HEAD.
   Request-only mode ends by reporting that review is already pending.

3. **Else** — fire the trigger:

   ```bash
   ./scripts/01-request-review.sh --pr <n>
   ```

   The script keeps its own `InFlight` short-circuit as a safety net,
   but the canonical "is Copilot pending?" signal lives in
   `02-check-review-status.sh` (above).

4. In request-only mode, report `TriggerLanded` or `InFlight` and end. Do
   not proceed to fixes or pushes. In full-loop mode, continue to step 2.
5. If requesting review fails for a confirmed availability or permission
   reason, repair mode may take the
   [single-iteration fallback](orchestration.md#single-iteration-fallback).
   Other failures need inspection: a missing trigger event or slow review
   does not prove Copilot is unavailable. Never manufacture a commit to
   recover a trigger; stop with the diagnostic if it cannot be verified.
