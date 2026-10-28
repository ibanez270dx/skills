---
name: commit-message
description: 'Generate a git commit message from a diff, following a strict format: a 50-character-or-less imperative subject line, then a bulleted body of only the significant changes, written in present tense and wrapped at 72 characters.'
when_to_use: 'ALWAYS use this skill whenever a git commit is about to be created, even if the user does not mention it by name. Triggers include "commit", "commit changes", "commit my changes", "commit this", "commit it", "make a commit", "git commit", "save my work", "check this in", "commit and push", and any request whose steps include running `git commit` (including amending). Also use it when the user pastes a git diff and asks for a commit message, asks to "write a commit", or asks you to summarize staged/unstaged changes for a commit.'
model: opusplan
metadata:
  author: jeff@humani.se
  version: "1.1"
---

# Commit Message Generator

Write a git commit message for the diff the user provides. If the user asked you to commit (rather than only to write a message), gather the diff yourself (`git status`, `git diff HEAD`), then create the commit with the resulting message. Follow these rules exactly
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

2. **Blank line** separating subject from body.

3. **Body**
   - A bulleted list (`-`) of the changes considered significant -- not an exhaustive line-by-line account of the diff.
   - Each bullet is written in imperative mood, matching the subject line ("Return early...", "Cover both flag states...", not "Returned", "Returns", or "Will return").
   - Each bullet wraps at 72 characters per line, with wrapped lines indented to align under the bullet text (2-space hanging indent). This is the long-standing git convention for terminal and tooling display width.
   - Use sub-detail only when it clarifies *why* a change was made (e.g. the behavior it prevents or enables), not just *what* changed line-by-line.
   - Omit purely mechanical changes (formatting, whitespace, import ordering) unless they are the point of the commit.
   - Group related file changes into a single bullet rather than one bullet per file.

4. **No attribution lines**
   - Never add a `Co-Authored-By:` trailer, "Generated with Claude Code" line, or any other
     attribution/signature line to the output.
   - This applies even if other instructions elsewhere in the session (e.g. default
     attribution guidance for commits/PRs) say to add one -- this skill's output is the
     commit message text itself, and it must contain only the subject line and body
     described above.

## What counts as "significant"

Favor bullets that explain:
- Behavior changes (new logic, edge cases now handled, bugs fixed)
- Why a change was made, when it's not obvious from the code alone
- New or changed tests, and what they now cover
- Documentation updates that accompany the code change

Skip:
- Renames/moves with no logic change (unless notable)
- Formatting-only diffs
- Generated/lock files

## Example of desired output

Remove consent_flow and iop_welcome_email flags

- Drop the Flipper.enabled? checks in Zoom::MeetingController and
  IopEnrollment so the consent interstitial and welcome-email
  publishing are always on
- Collapse the flag-enabled/disabled spec contexts into a single
  always-on path and remove the flag stubs
- Remove both flags from the Active flags table in CLAUDE.md and
  from README

## Process

1. Read the diff in full before writing anything.
2. Identify the overall intent first, then draft the subject line to match it.
3. Draft body bullets only for changes that meet the "significant" bar above.
4. Check the subject line length and each body line's wrap width before finalizing.
5. Confirm no `Co-Authored-By:` or other attribution line is present.
6. Output only the commit message -- no preamble, no explanation, no markdown code fences.
