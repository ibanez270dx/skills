# Harness Adaptation — Running This Loop Anywhere

This skill is written against an abstract agent runtime, not a
specific product. The loop logic, the scripts, and the convergence
rule are identical everywhere; only **who executes a step** changes.
Read this file once, at the start of the run, and pick your tier.

Nothing below changes what `Converged: true` means. Convergence is
computed by [scripts/02-check-review-status.sh](../scripts/02-check-review-status.sh)
from GitHub API state alone, so it is harness-independent by
construction. If a harness tier ever seems to require a different
convergence rule, the tier is being applied wrong.

## Two roles

| Role | Definition |
|---|---|
| **orchestrator** | The agent that owns the user conversation. Decides the loop, performs every mutation (push, reply, resolve), and writes the final message. There is always exactly one. |
| **worker** | Whatever executes a single delegable step. A separate sub-agent when the harness has one; otherwise the orchestrator itself, running the step inline. |

Steps are labelled **orchestrator-only** or **delegable**. An
orchestrator-only step must never be handed to a worker even when
delegation is available — those steps mutate the PR or the remote
branch, and a worker running them concurrently causes double-posts
and wrong-branch pushes.

## Worker capability classes

Steps request a *capability*, never a product's agent-type name. Map
each class onto the nearest thing your harness offers.

| Class | Needs | Used by |
|---|---|---|
| `inspect` | Read files, run read-only commands (`gh` reads, `git log`). No edits, no mutations. | steps 3, 9 |
| `edit` | Read + write files, run repo commands. | steps 4, 5, 8-draft |
| `run` | Execute long build/test/lint commands and report pass/fail with failure output. | step 6 |

If your harness has only one kind of worker, use it for all three —
the classes are a least-privilege preference, not a requirement.

## Tiers

Pick the highest tier your harness supports.

### Tier 1 — parallel workers + messaging

The harness can start several workers concurrently and send a
follow-up message to a running or idle one.

- Use the delegation map in [orchestration.md](orchestration.md) as written.
- Step 5 fans out, max 5 concurrent.
- The extension protocol applies: when a worker returns
  `status: partial` with a concrete `next_action`, the orchestrator
  sends it a "continue for N minutes" message, `N = min(needs_extension_minutes, 10)`.

### Tier 2 — workers, no parallelism or no messaging

The harness can start a fresh worker but runs them one at a time, or
cannot message one after it starts.

- Delegate the same steps, **serially**. Step 5 processes findings
  one at a time in triage-priority order.
- There is no extension protocol. A worker that returns `partial` is
  not resumed; the orchestrator re-dispatches a **narrower** slice
  (fewer threads in step 4, a single file or finding in step 5) in a
  new worker, or takes the step over itself.
- Budgets become the worker's instruction to summarize and return
  rather than a runtime cap.

### Tier 3 — no workers (single-agent harnesses)

The harness has no sub-agent primitive at all. **This is a supported
mode, not a degraded one** — the loop is sequential by nature and
only step 5 ever benefits from parallelism.

- The orchestrator runs every step inline, in canonical order.
- Budgets become self-imposed wall-clock checks: when a step exceeds
  its budget, stop, write down `status` / `next_action` in your own
  reply, and either narrow the step or hand off. Do not silently
  grind.
- Step 2 (wait) is the one step that must not be run as a blocking
  inline loop — see [02-wait.md](02-wait.md) for the sleep-and-poll
  form that works without a worker.
- **Context hygiene replaces fresh contexts.** Delegation's real
  benefit here is isolation: a worker reads a 400-line diff and
  returns four lines. Without workers you must do that compaction
  yourself. After each step, carry forward only the step's structured
  output (the triage verdicts, the thread ids, the pass/fail) and
  drop the raw command output and file contents it came from. Never
  re-read a file you have already summarized.
- If the context does fill up mid-loop, stop at a round boundary, not
  mid-round. The resumability snapshot in
  [orchestration.md](orchestration.md#notes) is the handoff.

## Vocabulary mapping

The step contracts use neutral terms. Translate once, here.

| This skill says | Means |
|---|---|
| "report completion" / "the final message" | Whatever ends the turn in your harness — a `task_complete`-style tool call, a `attempt_completion`, or simply the assistant's closing reply. The **content** is fixed: the convergence proof, the human hand-offs, and the squash message. |
| "dispatch a worker" | Start a sub-agent, or run the step inline (tier 3). |
| "continue instruction" | A follow-up message to a running worker. Tier 1 only. |
| "budget: N min" | A soft target. Tier 1/2: the worker's instruction. Tier 3: your own checkpoint. Never a reason to leave the PR half-replied. |
| `inspect` / `edit` / `run` worker | The capability classes above. |

## Platform assumptions (all tiers)

- **Shell:** `bash` 3.2+ (stock macOS). The scripts are POSIX-ish bash
  and use `gh` + `jq`. There is no PowerShell dependency and no
  Windows-native path handling — on Windows, run them under WSL or
  Git Bash.
- **Network + auth:** every script shells out to `gh`. A harness that
  sandboxes network access must grant it, or the loop cannot run at
  all; surface that as a prerequisite failure and stop.
- **Sandboxed / approval-gated shells:** steps 1, 7, 8 and 10 perform
  real mutations (`git push`, GraphQL writes). If the harness
  escalates those for user approval, batch them at the documented
  points rather than scattering approval prompts through a round.
