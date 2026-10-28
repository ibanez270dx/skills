# Step 3: List + categorize open threads

Owner: **delegable** to an `inspect`-class worker; budget: 5 min.
See [harness-adaptation.md](harness-adaptation.md).

## Inputs

- `PrNumber`.

## Return contract

Table of rows, one per open thread:

```
{ thread_id, file, line, author, author_class, human_participated,
  awaiting_reply, replies, severity, summary }
```

Where `author_class` ∈ `copilot` | `human-or-bot`, derived from the thread's
participants (see below and Gotchas). `human_participated`, `awaiting_reply`,
and `replies` come straight from the script's `HumanParticipated`,
`AwaitingReply`, and `Replies` fields.

## Procedure

Run the listing script:

```bash
./scripts/03-list-open-threads.sh --pr <n>
```

This returns every unresolved review thread from **all reviewers**
(Copilot, humans, `github-advanced-security`, other bots). The script
emits `Path` as `<file>:<line>` when the comment is anchored to a
specific line (e.g. `src/foo.js:42`); when the comment has no line
anchor (file-level / PR-level comments), `Path` is just `<file>` with
no `:<line>` suffix. Callers should split on the last `:` **only when
the suffix parses as an integer**, and treat `Path` as the file alone
otherwise. Each thread also carries its whole conversation: `Replies` (every
comment after the opener), `LastAuthor`, `AwaitingReply`, and
`HumanParticipated`. **Classify by who took part, not just who opened it:**

- `author_class: copilot` only when the opener is
  `copilot-pull-request-reviewer` (or `...[bot]`) **and**
  `HumanParticipated` is false (every other commenter is Copilot or us)
- everything else → `author_class: human-or-bot`, including a Copilot thread
  a human has replied to (`HumanParticipated: true`), because that reply is
  feedback that needs a response; the opener alone would hide it

A thread with more than 100 comments comes back `Truncated` with
`HumanParticipated: true` (forced, because the unseen middle may hold a human) and its
real last comment in `LastAuthor`. Escalate it rather than classify it from a partial
conversation.

Read `Replies` before deciding: it holds any human objection, and the
rationale of an earlier decline, so a revisited finding isn't re-litigated
from scratch or flipped without noticing.

Pass the classified table to step 4 — the triage rubric depends on it.

## Gotchas

- **The `[bot]` suffix appears on some surfaces.** Match BOTH
  `copilot-pull-request-reviewer` AND
  `copilot-pull-request-reviewer[bot]` — they're the same actor.
- **Default human / advanced-security threads to `escalate-to-user` in
  step 4.** Classification here just flags them; triage applies the
  policy. See [04-triage.md](04-triage.md).
- **Some findings live in the review body, not in a thread.** Copilot's
  "Previously missed (N)" section lists real findings in code that hadn't
  changed since the last review. They are unthreaded, so this script can't
  list them. `02-check-review-status.sh` reports them as
  `PreviouslyMissedCount` and never calls such a review clean (even when its
  header says "0 open findings"). Only the section heading counts (a
  `<summary>` or line starting `Previously missed (N)`): the phrase inside
  PR-overview prose or a finding's title does not. When the count is above 0, read
  the review with `./scripts/03-review-body.sh --pr <n>` (add `--raw` for just the
  markdown), triage each item with the step 4 rubric, fix it in the same round's
  commit, and, since there is no thread to resolve, post one PR comment citing the
  pushed SHA (`gh pr comment <n> --body ...`). Don't fetch the review with
  `gh api repos/<owner>/<repo>/pulls/<n>/reviews`: REST returns only the first 30
  reviews, oldest first, so on a long loop it omits the newest one. The script picks
  the review exactly as the status snapshot does (newest at HEAD, else newest), so its
  body always matches `PreviouslyMissedCount`.
- **Unresolved is the source of truth.** Outdated-but-unresolved
  threads still show up — that's correct. Don't filter them out;
  they're handled like any other open thread in step 8.
