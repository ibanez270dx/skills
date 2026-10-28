# Step 2: Wait for review

Owner: **delegable** to an `edit`-class worker; budget: **20-minute
hard cap** — a single bounded dispatch, never extended. Without a
worker, the orchestrator polls inline on the same schedule; see
[harness-adaptation.md](harness-adaptation.md).

**Skipped** when the loop is in [single-iteration
mode](orchestration.md#single-iteration-fallback) — there's no Copilot
review to wait for.

## Inputs

From step 1:
- `PrNumber`.
- `baseline` — the `LatestCopilotReview.submittedAt` string captured
  before the trigger fired (empty string if no prior Copilot review).

## Return contract

- `02-check-review-status.sh` JSON snapshot.
- `recommendation` ∈ {`ready`, `give-up-push-commit`}.
- `ready` iff **both** `LatestCopilotReview.submittedAt > baseline`
  AND `ReviewAtHead: true`.

## Procedure

Poll `02-check-review-status.sh` approximately every **3 minutes**
until `ready` or the 20-minute cap is hit:

```bash
./scripts/02-check-review-status.sh --pr <n>
```

- Extract `submittedAt` and `ReviewAtHead` from the JSON each tick.
- Stop and return `ready` on the first tick that satisfies both
  conditions vs. the captured `baseline`.
- On cap reached without `ready`, return `give-up-push-commit`.

### Without a worker (tier 3)

A single-agent orchestrator must not burn its own turns on seven
polling round-trips. Run the whole wait as one shell command that
sleeps between ticks and exits as soon as it is `ready`:

```bash
baseline='<submittedAt from step 1, or empty>'
for _ in 1 2 3 4 5 6 7; do
  snap=$(./scripts/02-check-review-status.sh --pr <n>) || exit 1
  at=$(printf '%s' "$snap" | jq -r '.LatestCopilotReview.submittedAt // ""')
  head=$(printf '%s' "$snap" | jq -r '.ReviewAtHead')
  if [ "$head" = "true" ] && [ "$at" \> "$baseline" ]; then
    printf '%s\n' "ready $snap"; exit 0
  fi
  sleep 180
done
printf 'give-up-push-commit\n'
```

Dispatch it with whatever "run in the background / long timeout"
facility the harness offers rather than a foreground call that may hit
a tool timeout at the 20-minute mark. ISO-8601 `submittedAt` values
sort correctly as strings, which is why `\>` works here.

## Gotchas

- **Don't poll faster than ~3 minutes.** There is no progress signal
  from the API; faster polling only burns budget.
- **`give-up-push-commit` fallback is orchestrator-driven.** When the
  worker returns this recommendation, the **orchestrator** pushes a
  substantive (non-whitespace) commit — auto-assign on `synchronize` is
  the most reliable trigger. Then the orchestrator re-enters the loop at
  step 1 with a fresh `baseline`.
- **Single bounded run, not extension-driven.** Do not request
  extensions on this step — if 20 min isn't enough, the right move is
  the `give-up-push-commit` fallback, not more polling.
