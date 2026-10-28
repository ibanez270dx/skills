# Step 11: Squash commit message

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a. Runs **once, after step 10**, only when
the loop has converged. It produces the message the human will paste into GitHub's
squash-merge box, and it is part of the completion report.

## Inputs

- `PrNumber` for the converged PR.

## Return contract

- The commit message, shown to the user inside a fenced `markdown` block (so it copies
  cleanly), as part of the completion message.

## Procedure

1. Read the PR as a whole, not the review loop's own history:

   ```bash
   gh pr view <n> --json title,body,headRefName
   gh pr diff <n>
   ```

2. Invoke the repo's **`commit-message` skill** on that diff. It owns the format (a subject
   of 50 characters or fewer in the imperative, then a bulleted body of the significant
   changes wrapped at 72 characters, and no attribution lines). Don't hand-write the
   message and don't restate its rules here.

3. Apply these PR-specific rules on top of it:
   - **Describe what the PR delivers, not how it got there.** The commits titled "Address
     Copilot review round N" are the loop's bookkeeping: leave them out. The squashed
     message should read as if the final state had been written in one go.
   - **Keep the ticket prefix.** If the PR title starts with a ticket key (e.g.
     `CORE-320: ...`), keep it as the subject prefix; the 50-character limit covers the
     whole subject line.
   - **Don't add the PR number.** GitHub appends `(#<n>)` to a squash commit's subject
     itself.
   - If a human-confirmation hand-off is outstanding (see `ReviewSummary` in step 9), do
     not bury it in the commit message: it belongs in the completion message.

4. Show the result to the user:

   ````markdown
   ```markdown
   CORE-123: Subject line in the imperative

   - First significant change
   - Second significant change
   ```
   ````

   (That is, a fenced block tagged `markdown`, containing only the message.)

## Gotchas

- **Don't run this before convergence.** A message written mid-loop describes a PR that is
  still changing.
- **The diff, not the PR body, is the source of truth.** PR descriptions drift from the
  final code across rounds; summarize what `gh pr diff` shows.
- This step never commits, pushes, or merges. It only prints the message.
