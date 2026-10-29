# Step 2: Wait for review

Owner: orchestrator launches a read-only shell process. No polling worker
is needed. Skip this step in request-only and limited-pass modes.

## Inputs

- `PrNumber` and optional `--owner` / `--repo` together.
- `baseline`: latest Copilot review's `submittedAt` captured before request;
  pass an empty string if no prior review exists.
- Expected published `HeadOid` from step 1.

## Procedure

Invoke the bundled script from the target repository, using the resolved
skill directory:

```bash
"$skill_dir/scripts/02-wait-for-review.sh" --pr <n> \
  --baseline "$baseline" --head "$head_oid"
```

Defaults: poll every 180 seconds for up to 1,200 seconds. The script reads
the existing status checker, sleeps internally, and emits only one compact
JSON result. Use background execution or the harness's completion facility
if a foreground command cannot remain open. Do not repeatedly wake a model
to re-run the GitHub query or print every snapshot.

## Return contract

`{ WaitStatus, ElapsedSeconds, Snapshot }`, where `Snapshot` is the latest
`02-check-review-status.sh` result:

| WaitStatus | Exit | Meaning |
| --- | --- | --- |
| `ready` | 0 | A newer Copilot review exists at the expected HEAD, with no review pending. Continue to triage, even if the review contains findings. |
| `timeout` | 124 | No qualifying review by the deadline. Report stopped with the snapshot; resume later using the same baseline and expected HEAD. |
| `head-changed` | 3 | The published PR HEAD changed. Inspect and revalidate before continuing. |
| `pr-closed` | 3 | PR is no longer open. Stop the loop. |

Other failures exit 1 with a diagnostic on stderr and must not be treated
as readiness. The deadline is checked between API calls; an in-progress
GitHub request may extend elapsed time beyond it.

Readiness means a review is available, not that it is clean or converged.
The script never edits code, pushes, requests another review, or posts a
comment. A timeout does not authorize those actions. Fixing a genuine
finding may later produce a substantive commit through the normal workflow.
