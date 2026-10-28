---
name: pr-review-loop
description: 'This skill runs loop engineering: auto-triggers Copilot Code Review via GraphQL (no @copilot mention), triages every open thread (Copilot, humans, advanced-security) with a fix / decline / escalate rubric, dispatches fix workers (in parallel where the harness supports it) that obey the repo build/test/lint conventions, commits per iteration, replies+resolves citing the pushed SHA, then re-triggers until HEAD is reviewed with zero threads awaiting the agent''s reply (remaining open threads are explicit hand-offs to the human — escalated declines, design tradeoffs). Trigger phrases: "address copilot comments", "run a copilot review loop", "fix this PR", "iterate on copilot feedback". Repo-agnostic and harness-agnostic (runs with or without sub-agents); bash + gh CLI + jq (macOS/Linux/WSL, no PowerShell). Full autopilot needs repo Triage/Write; external PR authors get single-iteration mode plus manual re-trigger (UI 🔄 or substantive-commit push).'
---

# PR Review Loop (Copilot)

Drive any GitHub pull request through repeated rounds of Copilot code
review until the agent has done its job — every Copilot finding has
a reply from the agent (fix-acknowledgement, decline-with-rationale,
or explicit escalate-to-user hand-off). Remaining open threads, if
any, are deliberate hand-offs to the human merge owner — they're
not loop failures. Repository-agnostic — works on any repo that has
Copilot Code Review enabled, run from a machine with `gh` CLI
installed and authenticated (see Prerequisites).

## When to Use This Skill

- The user asks to "request Copilot review" or "run a Copilot review loop"
  on a PR.
- A PR is functionally complete and the user wants a final correctness pass
  via repeated automated review rounds.
- A previous Copilot review on the PR has left open threads that need
  triage, fixing, replying, and resolving.

## When NOT to Use This Skill

- The PR is still under active design — wait until the structure is stable;
  otherwise findings churn round-over-round.
- The user wants human reviewer feedback, not Copilot's.

## Prerequisites

- `gh` CLI installed and authenticated against the target repository.
- `jq` and bash 3.2+ (the stock macOS bash). `brew install jq`. Nothing
  else: there is no PowerShell dependency. On Windows, run under WSL
  or Git Bash.
- Network access for `gh`. A harness that sandboxes the network must
  grant it, or the loop cannot run.
- Copilot Code Review is the primary use case (`01-request-review.sh`
  uses GraphQL `requestReviewsByLogin` to trigger Copilot). It is
  **NOT a hard requirement** — if `01-request-review.sh` fails
  because Copilot isn't enabled on the repo / account, the agent can
  still drive existing review threads (human, advanced-security, etc.)
  to completion by running steps 3–8 once as a single iteration; just
  skip the trigger + wait. There is no auto-detect for "Copilot
  unavailable" — the agent makes that decision after the trigger
  fails (the script can't reliably tell "Copilot disabled" from
  "Copilot enabled but not yet triggered" from API state alone).

### Permissions: who can run the full loop

The full multi-round autopilot (steps 1 → 9 → 1) needs **Triage or Write** permission on the target repo, because GitHub's only public API for adding the Copilot bot as a reviewer (`requestReviewsByLogin`) is gated on that permission. Verified against the public REST + GraphQL surface in this PR's commit history — there is no public-API path for bot reviewers without write permission.

| You are… | What works |
|---|---|
| **Repo collaborator with Triage / Write** | Full loop: `01` triggers Copilot, `02` waits, `04`–`08` triage / fix / reply, loop back to `01`. Hands-off. |
| **External PR author (no write permission)** | `01` will throw a clear actionable error. Use `--single-iteration` mode: address all current findings in one pass, then either click the UI 🔄 next to Copilot, **or** push a substantive commit (the `synchronize` event auto-triggers Copilot on most repos). Then re-run `02` to verify. |

In single-iteration mode the loop's convergence boolean is `Converged: true` iff `OpenThreadsAwaitingReply == 0` (the agent's side is done). The maintainer-side re-trigger then drives any additional rounds.

Every script sources [scripts/_lib.sh](scripts/_lib.sh), which checks
that `gh` and `jq` are on PATH and halts **before any work** with an
install hint if not. Authentication is deliberately not pre-checked
(a `gh auth status` call can fail transiently, e.g. on a keyring
timeout, and abort a run that would have worked): the first real `gh`
call reports a missing login with a single actionable message. The
agent should surface any `prerequisite missing` message to the user
verbatim and stop the loop — do not retry or work around it.

**Run the scripts from inside the target repo** (or pass `--owner` and
`--repo`). Without them the scripts resolve the repo from the current
directory's git remote, so running from, say, the skill's own folder
inside another clone targets the wrong repository. Every script prints
`Owner`/`Repo` in its JSON output so you can check.

## Harness Adaptation — Read This First

This skill is harness-agnostic. The loop, the scripts, and the
convergence rule are identical everywhere; only **who executes a step**
changes. Before round 1, read
[references/harness-adaptation.md](references/harness-adaptation.md)
and pick your tier:

| Tier | Harness capability | Effect on the loop |
|---|---|---|
| 1 | Parallel sub-agents **and** the ability to message a running one | Delegation map and extension protocol as written. |
| 2 | Sub-agents, but serial or unmessageable | Same steps, delegated serially. No extensions — re-dispatch a narrower slice. |
| 3 | **No sub-agent primitive at all** (e.g. plain single-agent CLIs) | Supported, not degraded. The orchestrator runs every step inline; budgets become self-checks; you do the context compaction delegation would have done for you. |

Steps are labelled **orchestrator-only** (never delegate — these
mutate the PR or the remote branch) or **delegable** to an `inspect` /
`edit` / `run` capability worker. `Converged: true` is computed from
GitHub API state alone, so it means exactly the same thing in every
tier.

## Step-by-Step Workflow

> **The loop:** steps 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9, then **back to step 1** if `Converged: false`. Repeat the 1→9 round until step 9 returns `Converged: true`; only then run steps 10 and 11 once and report completion. **At every 10th round, the orchestrator runs the [round-cap recap gate](references/09-convergence.md#round-cap--recap-gate-circuit-breaker) before looping back** — recap all prior rounds and stop if the loop has drifted out of the PR's original scope.

Each round runs steps 1–9; steps 10 and 11 run once after convergence. The orchestrator coordinates; each delegable step is a bounded unit of work whose only output is its structured return contract — in a tier-1/2 harness that isolation comes from a fresh worker context, in tier 3 you enforce it yourself. Cross-cutting protocol (time-boxing, extension, single-iteration fallback): [orchestration.md](references/orchestration.md).

0. **Preflight** _(orchestrator-only, once before round 1)_ — see [00-preflight.md](references/00-preflight.md)
1. **Request review** _(orchestrator-only)_ — see [01-request-review.md](references/01-request-review.md)
2. **Wait for review** _(delegable, 20-min cap)_ — see [02-wait.md](references/02-wait.md)
3. **List + categorize open threads** _(delegable `inspect`, 5 min)_ — see [03-list-threads.md](references/03-list-threads.md)
4. **Triage** _(delegable `edit`, 5 min per ≤5 threads)_ — see [04-triage.md](references/04-triage.md)
5. **Fix** _(delegable `edit`, parallel max 5, 5 min each)_ — see [05-fix.md](references/05-fix.md)
6. **Build + test per repo conventions** _(delegable `run`, 10 min)_ — see [06-build-test.md](references/06-build-test.md)
7. **Commit + push** _(orchestrator-only)_ — see [07-commit-push.md](references/07-commit-push.md)
8. **Reply (always) + resolve (conditional)** _(delegable draft, orchestrator posts)_ — see [08-reply-resolve.md](references/08-reply-resolve.md)
9. **Convergence verify** _(delegable `inspect`, 3 min)_ — see [09-convergence.md](references/09-convergence.md)
   - **`Converged: false` → loop back to step 1** for another round (re-trigger, wait, list, triage, fix, push, reply, re-check). Each round addresses Copilot's findings on the previous round's HEAD; the loop terminates as soon as Copilot has nothing new to say AND every open thread has a reply from the agent.
   - **`Converged: true` → exit the loop**, run steps 10 and 11 once, report completion with the proof, any human hand-offs, and the squash message.
   - **Whenever `09-review-round.sh` reports `RecapDue` (a 10-round boundary was reached, even if two reviews landed at once and stepped over it) → run the [round-cap recap gate](references/09-convergence.md#round-cap--recap-gate-circuit-breaker) before looping back.** Recap ALL prior rounds against the PR's original scope and pick a verdict: **CONTINUE**, **REVERT-AND-SHIP** (drop drifted commits, ship the in-scope ones), or **HAND-OFF** (escalate to the user). This is the circuit breaker that stops a runaway bot-review loop.
10. **Cleanup outdated** _(orchestrator, post-convergence, once)_ — see [10-cleanup.md](references/10-cleanup.md)
11. **Squash message** _(orchestrator, post-convergence, once)_ — see [11-squash-message.md](references/11-squash-message.md). Run the `commit-message` skill on the PR's diff and show the message to the user in a fenced `markdown` block, ready to paste into the squash-merge box.

**Surface the human hand-offs when you finish.** `Converged: true` means the *agent* has nothing left to do, not that no human action is requested. Copilot's header can read "Needs a closer look" with 0 findings and ask a person to confirm something (e.g. production preflight checks). `02-check-review-status.sh` returns that as `ReviewVerdict` / `ReviewSummary`; when the verdict is not "Approved", quote `ReviewSummary` verbatim in the completion message as an item for the human merge owner, alongside any threads left open as hand-offs.

Convergence is computed by [scripts/02-check-review-status.sh](scripts/02-check-review-status.sh) as a single `Converged: true` boolean. Do **not** report completion until it returns true; print the proof (`HeadOid`, `LatestCopilotReview.commitOid`, `submittedAt`) in the completion message.

## Gotchas

The bundled scripts enforce the hard correctness invariants (trigger landing via `copilot_work_started` event id, `Converged` requiring HEAD-match + zero-awaiting + at-HEAD review, single-iteration fallback semantics, PR-state guard). Trust them — don't re-derive. The notes below cover decisions the scripts can't make for you:

- **Reply to every open thread; resolve only when the loop owns the disposition.** For `fix` and `decline` threads, reply + resolve. For `escalate-to-user` threads, reply with the analysis but leave the thread OPEN (`08-reply-and-resolve.sh --no-resolve`) so the human merge owner can act on it. See [08-reply-resolve.md](references/08-reply-resolve.md).
- **Copilot threads are loop-owned; human / advanced-security / other-bot threads default to `escalate-to-user`.** Auto-resolving a human review thread can hide unaddressed concerns. See [04-triage.md](references/04-triage.md) for the rubric.
- **Read the review body, not just the threads.** Copilot can list real findings under "Previously missed (N)" in the review body, where there is no thread to list, reply to, or resolve. `02-check-review-status.sh` reports them as `PreviouslyMissedCount` and won't report `Converged: true` while any exist. Read the review with `scripts/03-review-body.sh`, handle those findings like threads, then reply with a PR comment. See [03-list-threads.md](references/03-list-threads.md).
- **Push only with the preflight's `Push command`.** A bare `git push` can publish to the wrong branch, or to `origin` for a fork PR. See [00-preflight.md](references/00-preflight.md).
- **`--no-resolve` replies are hand-offs.** `08-reply-and-resolve.sh --no-resolve` appends an invisible marker, and `10-cleanup-outdated.sh` never resolves a thread whose last comment carries it, even with `--force`, so an escalated thread can't be silently closed later. See [08-reply-resolve.md](references/08-reply-resolve.md).
- **One focused commit per round, not one per PR.** Bundling rounds destroys the audit trail of which finding drove which change and breaks `git bisect`. See [07-commit-push.md](references/07-commit-push.md).
- **Build/test/lint with the repo's own commands** (per its `CONTRIBUTING` / `AGENTS` / `README` / `package.json` / `Makefile`) before pushing a fix. Discovery procedure: [06-build-test.md](references/06-build-test.md).
- **Push back with written rationale** when a Copilot finding would over-engineer the design for a hypothetical edge case. Auto-accepting every suggestion erodes the design — see the `decline` path in [04-triage.md](references/04-triage.md).
- **Scripting traps** (`gh api graphql -F` type-coercion, `git stash push -m` positional parsing, the three GraphQL traps for the reviewer mutation) are documented in [references/api-quirks.md](references/api-quirks.md). Read before modifying any script.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Script reports `prerequisite missing — gh is not on PATH` (or `jq`) | `brew install gh jq`, then `gh auth login`. Surface the message to the user and STOP the loop — do not retry. |
| Script reports `prerequisite missing — gh is not authenticated` | Run `gh auth login`. STOP the loop until the user completes auth. |
| Trigger fails or no `copilot_work_started` event lands | Push a substantive (non-whitespace) commit — auto-assign on `synchronize` is the most reliable trigger. Persistent failure indicates Copilot Code Review may not be enabled on the repo / account (check repo Settings → Code & automation → Copilot, or account-level Copilot Pro/Pro+). |
| No new review after waiting ~10 min | Quiet-period after recent dismissal or trivial-diff suppression. Push a substantive commit and retry. Do not blindly re-run `01-request-review.sh` — it reports `InFlight` while Copilot is still a requested reviewer. |
| Outdated-but-unresolved threads in the open list | Expected: unresolved state is the source of truth. Reply + resolve them like any other open thread. `10-cleanup-outdated.sh` is only a final safety net. |
| A script reports `GraphQL errors` or a `gh` failure | Read the message (it names the call and the GraphQL `type`/`code`). Reads already retry transient failures twice. Mutations are never auto-retried inside a script. `08-reply-and-resolve.sh` is safe to simply re-run: it skips a reply that is already the thread's last comment. |
| Output names an unexpected `Owner`/`Repo` | You ran the script from the wrong directory. Re-run from inside the target repo or pass `--owner` and `--repo`. |
| Unsure whether to fix or decline a finding | See [references/04-triage.md](references/04-triage.md). |
| Need a reply phrasing for "fixed", "declined", or "drift" | See the templates under [templates/](templates/) — [reply-fix.md](templates/reply-fix.md), [reply-decline.md](templates/reply-decline.md), [reply-drift.md](templates/reply-drift.md), [reply-partial.md](templates/reply-partial.md). |

## References

- [references/harness-adaptation.md](references/harness-adaptation.md) —
  **read first**: the orchestrator / worker roles, the `inspect` /
  `edit` / `run` capability classes, the three harness tiers
  (including no-sub-agent single-agent mode), the vocabulary mapping,
  and the platform assumptions.
- [references/orchestration.md](references/orchestration.md) —
  cross-cutting loop control: time-boxing & extension protocol,
  delegation map, single-iteration fallback, and loop-wide
  notes.
- Per-step contracts (one `NN-*.md` per step):
  [references/01-request-review.md](references/01-request-review.md) _(orchestrator-only)_,
  [references/02-wait.md](references/02-wait.md),
  [references/03-list-threads.md](references/03-list-threads.md),
  [references/04-triage.md](references/04-triage.md) (includes the
  fix-vs-decline rubric),
  [references/05-fix.md](references/05-fix.md),
  [references/06-build-test.md](references/06-build-test.md),
  [references/07-commit-push.md](references/07-commit-push.md) _(orchestrator-only)_,
  [references/08-reply-resolve.md](references/08-reply-resolve.md),
  [references/09-convergence.md](references/09-convergence.md) (includes
  the round-cap recap gate),
  [references/10-cleanup.md](references/10-cleanup.md) _(orchestrator-only)_,
  [references/11-squash-message.md](references/11-squash-message.md) _(orchestrator-only)_.
- [references/api-quirks.md](references/api-quirks.md) — verified
  GitHub API behavior, dead-ends, and the GraphQL traps for the
  reviewer mutation.
- Templates (one per reply type):
  [templates/reply-fix.md](templates/reply-fix.md) — accepted-fix
  pattern; [templates/reply-decline.md](templates/reply-decline.md) —
  declined-with-rationale pattern;
  [templates/reply-drift.md](templates/reply-drift.md) —
  PR-description / comment / test-plan drift acknowledgement;
  [templates/reply-partial.md](templates/reply-partial.md) —
  partial fix with deferred follow-up. Cross-cutting reply guidance
  and anti-patterns live in
  [references/08-reply-resolve.md](references/08-reply-resolve.md#reply-guidance).
- [scripts/00-preflight.sh](scripts/00-preflight.sh) —
  verifies the checkout matches the PR's head branch/repo and prints the
  verified push command (step 0).
- [scripts/_lib.sh](scripts/_lib.sh) — shared helpers (`gh_capture`,
  `gh_graphql`, `resolve_repo`, and the jq definitions that judge a
  review body); sourced by every script.
- [scripts/01-request-review.sh](scripts/01-request-review.sh) —
  trigger Copilot review and verify pickup via the
  `copilot_work_started` event.
- [scripts/02-check-review-status.sh](scripts/02-check-review-status.sh) —
  single-shot snapshot of the PR's Copilot review state; emits
  `Converged: true` only when all three conditions hold.
- [scripts/03-list-open-threads.sh](scripts/03-list-open-threads.sh) —
  every unresolved PR review thread from **all reviewers** (Copilot,
  humans, github-advanced-security, etc.).
- [scripts/03-review-body.sh](scripts/03-review-body.sh) —
  the latest Copilot review with its body, for findings that live in the body
  ("Previously missed") rather than in a thread.
- [scripts/08-reply-and-resolve.sh](scripts/08-reply-and-resolve.sh) —
  post a reply and resolve in one call; safe to re-run (skips a reply that is
  already the thread's last comment).
- [scripts/09-review-round.sh](scripts/09-review-round.sh) —
  deterministic Copilot-review round count and recap-due flag; `--ack` records that
  the recap was run (a PR comment with a hidden marker).
- [scripts/10-cleanup-outdated.sh](scripts/10-cleanup-outdated.sh) —
  safety net for outdated Copilot threads.
- [tests/run.sh](tests/run.sh) — offline tests for every script, driven
  by a fake `gh` (no network). Run it after changing a script.
