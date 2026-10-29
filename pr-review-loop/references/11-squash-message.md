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

1. Read the entire branch's final PR diff, not just the review loop's fixes
   or latest commit. Identify the actual base and published head:

   ```bash
   gh pr view <n> --json title,body,baseRefName,headRefName,baseRefOid,headRefOid
   gh pr diff <n>
   ```

   Inspect the complete changed-file list and diff, in chunks if output
   is truncated. Use branch history only as context for the final changes.
   For local comparisons, use current verified refs and the merge-base
   comparison `git diff <base>...<head>`, not a working-tree or last-commit
   diff. Refresh the comparison if the published head changes.

   Find associated tickets through PR issue/development links, closing
   references, and IDs/URLs in the title, body, discussion, branch name,
   or commits. Retrieve their descriptions, acceptance criteria, and relevant
   clarifications using available read-only integrations or authenticated
   tools, including external trackers. Verify that a mention is actually
   associated with this PR. Use ticket context for intent and the final diff
   for delivered behavior; never claim inaccessible ticket details or
   unverified acceptance criteria. Do not update tickets while drafting.

2. Use the **`commit-message` skill** when installed. It is optional; this
   skill must also work when installed alone. Without it, draft a message
   using this bundled fallback: an imperative subject of 50 characters or
   fewer with no trailing period, a blank line, a short paragraph of one or
   two sentences explaining the intent, another blank line, then
   significant-change bullets in imperative mood. Ground the intent in the
   diff and task context. Wrap the paragraph and bullets at 72 columns;
   use two-space hanging indents for bullets. Omit mechanical trivia and
   attribution/signature lines.
   Check the lengths before presenting the result.

3. Apply these PR-specific rules on top of it:
   - **Describe what the PR delivers, not how it got there.** The commits titled "Address
     Copilot review round N" are the loop's bookkeeping: leave them out. The squashed
     message should read as if the final state had been written in one go.
   - **Cover every significant outcome across the branch.** More detail is
     appropriate for a broad PR, but group related changes, put the main
     outcome first in each bullet, and order bullets by importance. Keep
     the intent paragraph short; avoid a commit-by-commit or file-by-file
     inventory. Check the draft against the full diff and changed-file list.
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

   Explain the problem this commit addresses or the outcome it enables.

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
