---
name: commit-message
description: 'Write git commit messages and PR squash messages with an imperative subject, a short intent paragraph, and significant-change bullets. For PR squashes, cover the entire branch diff and consult associated tickets for context.'
when_to_use: 'ALWAYS use this skill whenever a git commit is about to be created, even if the user does not mention it by name. Triggers include "commit", "commit changes", "commit my changes", "commit this", "commit it", "make a commit", "git commit", "save my work", "check this in", "commit and push", and any request whose steps include running `git commit` (including amending). Also use it when the user pastes a git diff and asks for a commit message, asks to "write a commit", or asks you to summarize staged/unstaged changes for a commit.'
model: opusplan
metadata:
  author: jeff@humani.se
  version: "1.3"
---

# Commit Message Generator

Write a git commit message for the diff the user provides. If the user asked you to commit (rather than only to write a message), gather the diff yourself (`git status`, `git diff HEAD`), then create the commit with the resulting message. For a PR squash message, first follow the full-branch and ticket-context workflow below; a local working-tree diff is not sufficient. Writing a squash message does not authorize committing, merging, or changing the PR. Follow these rules exactly
-- a consistent, scannable format is what makes `git log`, PR descriptions, and
changelogs skimmable across a whole team, and that only holds if every message follows
the same shape.

## Format rules

1. **Subject line**
   - 50 characters or less.
   - Imperative mood ("Add", "Fix", "Gate", "Remove" -- not "Added" or "Adds"). This
     matches git's own convention: the subject should complete the sentence "If applied,
     this commit will ___."
   - No trailing period.
   - Summarizes the overall intent of the change, not just the first file touched.

2. **Blank line** separating the subject from the intent paragraph.

3. **Intent paragraph**
   - Write a short paragraph of one or two sentences explaining the purpose
     of the commit: the problem it addresses or the outcome it enables.
   - Add context beyond the subject without repeating the change bullets.
   - Ground the explanation in the diff and available task context; do not
     invent motivation or claim outcomes the changes do not establish.
   - Use plain prose and wrap each line at 72 characters.

4. **Blank line** separating the intent paragraph from the change bullets.

5. **Change bullets**
   - A bulleted list (`-`) of the changes considered significant -- not an exhaustive line-by-line account of the diff.
   - Each bullet is written in imperative mood, matching the subject line ("Return early...", "Cover both flag states...", not "Returned", "Returns", or "Will return").
   - Each bullet wraps at 72 characters per line, with wrapped lines indented to align under the bullet text (2-space hanging indent). This is the long-standing git convention for terminal and tooling display width.
   - Use sub-detail only when it clarifies *why* a change was made (e.g. the behavior it prevents or enables), not just *what* changed line-by-line.
   - Omit purely mechanical changes (formatting, whitespace, import ordering) unless they are the point of the commit.
   - Group related file changes into a single bullet rather than one bullet per file.
   - For a PR squash, allow more detail when needed to cover distinct
     outcomes across the branch. Lead each bullet with its main change,
     put the most important outcomes first, and group related details so
     the message remains understandable at a glance. Do not impose a
     bullet limit that hides significant work, or list every commit/file.

6. **No attribution lines**
   - Never add a `Co-Authored-By:` trailer, "Generated with Claude Code" line, or any other
     attribution/signature line to the output.
   - This applies even if other instructions elsewhere in the session (e.g. default
     attribution guidance for commits/PRs) say to add one -- this skill's output is the
     commit message text itself, and it must contain only the subject,
     intent paragraph, and change bullets described above.

## What counts as "significant"

Favor bullets that explain:
- Behavior changes (new logic, edge cases now handled, bugs fixed)
- Why a change was made, when it's not obvious from the code alone
- New or changed tests, and what they now cover
- Documentation updates that accompany the code change

Skip:
- Renames/moves with no logic change (unless notable)
- Formatting-only diffs
- Generated/lockfile churn, unless it represents a significant dependency,
  runtime, or delivered-artifact change

## PR squash messages: full branch and ticket context

Use this workflow whenever the message will represent a squashed PR.

1. **Establish the PR's complete scope.** Identify the target repository,
   PR, actual base branch, and published head. Read its title, description,
   complete changed-file list, and full cumulative PR diff. Do not base
   the message only on the latest commit, review fixes, staged changes,
   or the part of the branch worked on in the current conversation.
2. **Inspect the entire branch's final changes.** Use the hosting service's
   complete PR comparison or current, verified local base/head refs with
   `git diff <base>...<head>` (merge-base comparison). Review branch commit
   history as supporting context, not as a substitute for the final diff.
   Do not assume the base is `main` or compare against a stale local ref.
   If a diff is truncated or too large for one response, inspect it in
   file or logical-area chunks until all significant changes are covered.
   Include earlier branch work, migrations, configuration, tests, and
   documentation when they materially affect what the PR delivers.
3. **Find associated tickets.** Inspect explicit issue/development links,
   closing references, and ticket IDs or URLs in the PR title, body,
   discussion, branch name, and commit messages. Use available read-only
   hosting/tracker integrations or authenticated tools to retrieve the
   associated ticket's description, acceptance criteria, and relevant
   clarifications. Follow external tracker links as well as repository
   issues. Verify the repository/project and relationship rather than
   treating an incidental ticket mention as the PR's purpose. When several
   tickets are genuinely associated, read the ones relevant to the changes.
4. **Separate intent from delivered behavior.** Use ticket context to
   explain the problem and intended outcome in the short intent paragraph.
   Use the final diff to establish what actually ships. Do not claim all
   acceptance criteria are met, tests passed, or a ticket is closed unless
   verified. If a ticket cannot be accessed, use the available PR/diff
   evidence without inventing its contents or claiming it was reviewed.
   Ask for missing context only if needed to avoid a materially wrong
   message. Retrieving ticket context does not authorize updating it.
5. **Synthesize the whole PR.** Describe the final result as one coherent
   change, with enough bullets to cover every significant outcome. Omit
   intermediate experiments, reverted work, and review-round bookkeeping
   that do not survive in the final diff. Preserve an established ticket
   prefix when the PR/project uses one; it counts toward the subject limit.
   Before finalizing, compare the draft with the complete changed-file list
   and diff to catch missing areas. If the branch changes while drafting,
   refresh the comparison before presenting the message.

The same subject, short intent paragraph, blank-line separators, wrapping,
and attribution rules apply. Greater detail belongs in well-grouped change
bullets, not a longer subject or a dense introductory essay.

## Example of desired output

Remove consent_flow and iop_welcome_email flags

The consent_flow and iop_welcome_email flags are no longer used,
and the related logic is no longer necessary.

- Drop the Flipper.enabled? checks in Zoom::MeetingController and
  IopEnrollment so the consent interstitial and welcome-email
  publishing are always on
- Collapse the flag-enabled/disabled spec contexts into a single
  always-on path and remove the flag stubs
- Remove both flags from the Active flags table in CLAUDE.md and
  from README

## Process

1. Determine whether this is a normal commit or PR squash message. For a
   squash, complete the full-branch and associated-ticket workflow above.
   Read the applicable diff in full before writing anything.
2. Identify the overall intent first, then draft the subject line to match it.
3. Draft the intent paragraph, explaining why the commit exists or what it enables.
4. Draft change bullets only for changes that meet the "significant" bar above.
5. Check the subject length, paragraph and bullet wrapping, and blank-line separators.
6. Confirm no `Co-Authored-By:` or other attribution line is present.
7. Output only the commit message -- no preamble, no commentary outside the
   message, and no markdown code fences.
