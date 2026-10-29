# Custom agent skills

My reusable agent skills, maintained in one place and shared across coding
harnesses such as Copilot, Claude Code, and Codex.

Each top-level skill folder is an independent package. To install a skill,
symlink its entire folder into each harness's skill discovery directory.
The files in this checkout remain the source of truth, so edits are
available through every installation without copying or reinstalling.
A running harness may need a refresh or a new session to load changes.

## Available skills

| Skill | Purpose |
| --- | --- |
| [commit-message](commit-message/SKILL.md) | Generate concise, consistently formatted git commit messages. |
| [pr-review-loop](pr-review-loop/SKILL.md) | Request Copilot PR reviews and iterate on review feedback. |

Harness agnostic refers to the agent executing a skill. Individual skills
can still require a particular service or CLI, such as GitHub and `gh`.
Read each skill's prerequisites before using it.

## Layout

```text
skills/
├── AGENTS.md
├── README.md
└── <skill-name>/
    ├── SKILL.md          # Entry point: metadata and instructions
    ├── scripts/          # Optional executable helpers
    ├── references/       # Optional supporting instructions
    ├── templates/        # Optional reusable templates
    └── assets/           # Optional supporting files
```

## Install

Keep this checkout at a stable local path. Create one symlink per skill
in each installed harness you want to use. Leave each discovery directory
as a real directory so other skills can coexist there.

The following personal discovery paths are documented by the harnesses:

| Harness | Personal skill directory | Documentation |
| --- | --- | --- |
| Copilot CLI | `~/.copilot/skills/` | [GitHub agent skills](https://docs.github.com/en/copilot/concepts/customizations/agent-skills) |
| Copilot in VS Code | `~/.copilot/skills/` | [VS Code agent skills](https://code.visualstudio.com/docs/agent-customization/agent-skills) |
| Claude Code | `~/.claude/skills/` | [Claude Code skills](https://code.claude.com/docs/en/skills) |
| Codex | `~/.agents/skills/` | [OpenAI skill documentation](https://learn.chatgpt.com/docs/build-skills) |

Paths and discovery behavior can vary by version and configuration. For
other harnesses, find their documented discovery directory and use the
same per-skill linking approach. Avoid installing the same skill into
multiple directories scanned by one harness.

### Example: install one skill in several harnesses

Run from this repository's root in Bash or Zsh. Adjust the destinations
to include only the harnesses you use. This example installs
`commit-message`; change `skill` to install another skill.

```sh
skills_repo="$(pwd -P)"
skill="commit-message"

if [ -f "$skills_repo/$skill/SKILL.md" ]; then
  for skills_dir in \
    "$HOME/.copilot/skills" \
    "$HOME/.claude/skills" \
    "$HOME/.agents/skills"
  do
    destination="$skills_dir/$skill"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      printf 'Already exists; inspect before changing: %s\n' "$destination"
      continue
    fi
    mkdir -p "$skills_dir" || break
    ln -s "$skills_repo/$skill" "$destination" || break
  done
else
  printf 'No skill found: %s\n' "$skills_repo/$skill/SKILL.md"
fi
```

The existence check preserves files, directories, and even broken symlinks.
Inspect an existing destination before deciding whether to keep or replace
it. Link the complete skill folder so bundled scripts and references are
available with `SKILL.md`.

For a project-specific installation, use the target project's discovery
directory instead: `.github/skills/` for Copilot, `.claude/skills/` for
Claude Code, or `.agents/skills/` for Codex. Keep links to a personal
checkout out of shared project commits: other machines and remote agents
need their own checkout and installation.

### Verify and remove

Inspect a link and check that the entry point is readable:

```sh
ls -ld "$HOME/.agents/skills/commit-message"
test -r "$HOME/.agents/skills/commit-message/SKILL.md"
```

Refresh or start the harness and confirm that the skill appears in its
skill list or can be invoked. A readable link checks the filesystem;
discovery must also be checked in the harness you use. Local symlinks
require filesystem support and access to the source checkout; hosted or
remote sessions need the skills installed in their own environment.

To uninstall, remove only the symlink at the chosen destination:

```sh
destination="$HOME/.agents/skills/commit-message"
if [ -L "$destination" ]; then
  rm "$destination"
fi
```

This leaves the source skill intact. Moving or deleting this checkout
breaks its installation links; recreate them after moving it.

## Authoring skills

Create a top-level folder with a `SKILL.md` entry point:

```markdown
---
name: example-skill
description: Describe what the skill does and when an agent should use it.
---

# Example skill

Explain the workflow, prerequisites, expected result, and how to verify it.
```

Keep instructions portable and resources inside the skill's folder. Make
harness-specific features optional and document alternatives when needed.
Use relative links for references, and tell the agent to resolve helper
paths from the skill's installed directory while preserving the target
project's working context. Include useful trigger conditions in the
description so discovery does not depend on a harness-specific field.

See [AGENTS.md](AGENTS.md) for repository contribution guidance.
