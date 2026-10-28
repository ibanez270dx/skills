# Step 0: Preflight

Owner: **orchestrator-only** (never delegate — see [harness-adaptation.md](harness-adaptation.md)); budget: n/a. Run **once before the first round**,
and again before step 7 if the checkout may have changed (another branch checked out,
rebased, or pulled).

## Why

Every other script talks to the GitHub API about whichever PR `--pr` names, whatever is
checked out locally. Step 7 then runs plain `git commit` and `git push`. Without this check,
running from the right repo while on `main` (or on a different PR's branch) would publish
the loop's fixes to the wrong branch, and a fork PR would push to `origin` instead of the
head repository's remote.

## Inputs

- `PrNumber` (or URL / branch name).

## Return contract

- Exit `0` and a report that ends with `all clear` (or advisory `WARN` lines), **including
  the exact `Push command`** to use in step 7.
- Exit `1` with `STOP:` lines. Do not continue until each one is fixed.

## Procedure

```bash
./scripts/00-preflight.sh --pr <n>
```

It verifies the PR is open, the checked-out branch is the PR's head branch, the head
branch isn't the default/shared branch, a local remote really points at the head repo (so
forks work), and the local branch isn't behind the remote. It also reports whether HEAD is
yours and a non-merge commit (i.e. whether amending is safe).

Typical fixes for a `STOP`:

- Wrong branch checked out: `gh pr checkout <n>`.
- No remote for a fork's head repo: `git remote add <name> <fork-url>`.
- Behind the remote: pull or rebase first.

## Gotchas

- **Use the printed `Push command` in step 7, never a bare `git push`.** It is
  shell-escaped, because a PR can name its head branch anything git allows, including shell
  metacharacters.
- A `WARN` about uncommitted changes means the work tree holds something that isn't from
  this round. Decide what belongs in the round's commit before committing.
