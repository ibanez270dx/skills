# Harness adaptation

Run the workflow with one agent by default. The scripts and completion
evidence are the same across harnesses; tool names and delegation support
do not change correctness requirements.

## Roles and optional workers

The **orchestrator** is the agent coordinating the user conversation. It
owns remote mutations, branch/push decisions, triage decisions, and the
final completion claim. A **worker** performs a bounded task when delegation
is supported, permitted, and useful. Otherwise the orchestrator performs
that task inline. Step contracts use these capability labels:

| Class | Capability |
| --- | --- |
| `inspect` | Read files and run read-only commands. |
| `edit` | Inspect and edit assigned files; run relevant local checks. |
| `run` | Execute validation and summarize failures or success. |

Delegate independent investigations, disjoint fixes, or long validation
when doing so helps. Serialize edits to the same files and respect runtime
concurrency limits. Workers return affected finding IDs, changes, validation,
and any remaining action. Workers may draft replies; only the orchestrator
posts them. A partial result is a checkpoint, not proof of completion.

Step budgets in individual references are planning estimates. They do not
require a worker, a particular model, or a messaging/extension API. Narrow
work or report a blocker when needed; preserve enough state to resume.

## Waiting

Use `02-wait-for-review.sh` in every harness. It polls and sleeps inside the
shell process, returning a single JSON result at readiness, timeout, or a PR
state change. Do not create a model-driven polling worker. A harness may
require background execution and occasional process checks; use its wait
or completion-notification facility without tight polling or repeated full
status dumps. Keep user updates consistent with the harness's requirements.

## Paths and platform

- Resolve the skill directory from the installed `SKILL.md` location; keep
  the target project as the working directory and invoke scripts by absolute
  path. Symlink installation includes all bundled resources.
- Bash 3.2+, `git`, `gh`, `jq`, and standard Unix utilities are required.
  On Windows use WSL or Git Bash; native PowerShell is not supported.
- Network and GitHub authentication must be available. Follow actual
  harness permission requirements; these instructions do not bypass them.
- Read references only when needed. Keep concise records of findings,
  dispositions, published HEAD, checks, and outstanding actions. Re-read
  source when changes or uncertainty require it.
