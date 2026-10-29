# Step 5: Apply fixes

Owner: orchestrator, optionally delegated to `edit`-class workers.
Process fixes serially by default. Parallelize only disjoint edits when
supported and useful, within the harness's limits; group related findings
when they share a coherent fix. See
[harness-adaptation.md](harness-adaptation.md).

## Inputs

Per finding or coherent group:
- `thread_id`, `file`, `line` from step 3.
- The finding `summary` and Copilot's suggested fix (if any).
- The triage `rationale` from step 4 — the agent already decided this
  is a `fix`; this worker only implements it.

## Return contract

```
{ thread_id, files_touched, summary, status }
```

Where `status` ∈ `complete` | `partial` | `blocked` and `summary` is
a one-line description of the change.

## Procedure

1. **Discover repo conventions for the area being edited — first.**
   Before writing any code, read:
   - `.github/instructions/*.md` whose `applyTo` glob matches the
     file's path,
   - `.github/skills/`,
   - `AGENTS.md`,
   - `CONTRIBUTING.md`,
   - neighbor-file patterns in the same directory and recent commits
     touching similar files.
2. Apply the fix in line with those conventions.
3. Return `files_touched` + a one-line `summary` + `status`.

## Gotchas

- **Serialize overlapping edits.** Reconcile all changes before step 6;
  respect the runtime's concurrency limits when using optional workers.
- **Never invent a generic answer that contradicts repo practice.**
  That's the "elephant in school" anti-pattern — a Copilot suggestion
  in isolation looks right but breaks the project's lint, format,
  spell-check, license-header, or framework conventions. The
  discovery step is mandatory, not optional.
- **Keep finding IDs traceable.** A grouped fix must identify each finding
  it addresses so validation and replies cover them all.
- **Project policy beats Copilot suggestion.** If discovery surfaces
  a documented convention (spell-check allowlist mechanism, lint
  suppression style, etc.) that contradicts the suggested fix, follow
  the convention and reflect that in the reply body drafted in step 8
  (see [04-triage.md](04-triage.md#project-specific-policy-hooks)).
- **Push back with written rationale** if implementing the fix would
  over-engineer the design for a hypothetical edge case — flip the
  triage to `decline` and return `status: blocked` with the rationale
  so step 8 drafts the right reply.
