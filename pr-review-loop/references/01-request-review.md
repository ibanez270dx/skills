# Step 1: Request review

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a.

## Inputs

- `PrNumber` for the target PR.

## Return contract

- Captured `baseline` = `LatestCopilotReview.submittedAt` string (or empty)
  to be passed to step 2.
- Boolean `single_iteration_mode` — `true` if the trigger failed because
  Copilot isn't a valid reviewer; `false` otherwise.

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

2. **If `pending`** — skip the trigger; jump to step 2 with `baseline`.

3. **Else** — fire the trigger:

   ```bash
   ./scripts/01-request-review.sh --pr <n>
   ```

   The script keeps its own `InFlight` short-circuit as a safety net,
   but the canonical "is Copilot pending?" signal lives in
   `02-check-review-status.sh` (above).

4. If `01-request-review.sh` fails because Copilot isn't a valid
   reviewer (Copilot Code Review not enabled on the repo / account),
   take the [single-iteration fallback](orchestration.md#single-iteration-fallback).
