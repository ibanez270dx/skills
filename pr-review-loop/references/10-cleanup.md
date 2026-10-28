# Step 10: Cleanup outdated

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a. Runs **once, after
convergence** (step 9 returned `Converged: true`).

## Inputs

- `PrNumber` for the converged PR.

## Return contract

- None. After it runs, continue to step 11 ([11-squash-message.md](11-squash-message.md));
  then the loop is complete and the orchestrator reports completion with the convergence proof from
  step 9.

## Procedure

```bash
./scripts/10-cleanup-outdated.sh --pr <n>
```

It never resolves: a thread with any non-Copilot, non-us commenter or a ghost
author; a thread where someone else spoke last (unless `--force`); or a thread
whose last comment is our `--no-resolve` reply, which carries the hand-off
marker (not overridable, since that thread was left open on purpose for a human).
Use `--dry-run` to see what it would resolve.

Safety net only. Most loops converge with nothing to clean — outdated
threads should already have been replied + resolved in step 8 like any
other open thread. Unresolved state is the source of truth in the PR
UI; `10-cleanup-outdated.sh` only catches strays.
