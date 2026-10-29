# Repository guidance

This repository is the source of truth for Jeff's custom agent skills.
Skills must be usable across harnesses, including Copilot, Claude Code,
and Codex. Read [README.md](README.md) for the layout and installation model.

## Skill structure

- Keep each skill in its own top-level directory, named with lowercase
  letters, numbers, and hyphens.
- Use `SKILL.md` as the entry point, with YAML frontmatter containing at
  least `name` and `description`. Match the name to the directory and make
  the description explain when to use the skill.
- Keep supporting scripts, references, templates, and assets inside that
  skill's directory. Use relative links for bundled resources.
- Keep skills independently installable. Avoid dependencies on sibling
  skills or repository-root files at runtime; document any required
  external tools or services explicitly.

## Harness portability

- Express instructions in terms of capabilities and outcomes, rather than
  a particular harness's tool names, model aliases, paths, or session APIs.
- Keep the core workflow in portable Markdown and standard frontmatter.
  Harness-specific metadata or adapters must be optional; a skill must
  remain useful when another harness ignores them.
- When execution differs by harness, isolate those differences in a
  clearly labeled reference and provide a single-agent fallback for
  workflows that can run without delegation.
- Resolve bundled script and resource paths from the installed skill's
  directory. Do not assume the current working directory is this repo,
  or change away from a target project when a workflow needs its context.
- State shell, platform, dependency, and permission requirements. Do not
  claim compatibility that has not been checked.

## Installation contract

- The installable unit is one complete skill directory. Installation
  creates a symlink from a harness's skill discovery directory to that
  directory in this checkout.
- Keep harness discovery directories as real directories; link individual
  skills inside them. Preserve unrelated skills and harness-managed files.
- Edit the canonical files here. Do not create separate copies for each
  harness or commit machine-specific installation links to this repo.
- Use absolute symlink targets for local installations. Never overwrite
  an existing file, directory, or link without inspecting it first.
- Only change local harness installations when the user's task includes
  installation or removal; editing a skill does not require relinking it.

## Making changes

- Read the full skill and affected references or scripts before editing.
  Preserve existing behavior outside the requested scope.
- Keep the README's skill list and installation guidance current when
  adding, renaming, or removing skills.
- Check frontmatter, relative resource links, examples, and portability
  assumptions. Run syntax checks and relevant existing tests when changing
  executable code; use focused checks for documentation-only changes.
- Treat edits as potentially live: installed harnesses read this checkout
  through symlinks. Avoid running workflows with remote side effects just
  to validate documentation.
- Report what changed and what was verified, including any harness behavior
  that still needs a live discovery check.
