# Skills Installer Agent Guide

Follow `~/AGENTS.md` first. This file adds project-local rules for the
`skills-installer` wrapper.

## Fast Start

- Read `README.md`, `Makefile`, and the touched script or test before editing.
- Keep changes scoped to `install_external_agent_skills.sh`, `config/`, `tests/`,
  and matching docs.
- Before handoff, run `markdownlint --config /Users/mmassari/.markdownlint.json`
  on edited Markdown files and `shellcheck --enable=all` on edited shell files.
- If you materially edit `README.md`, refresh its table of contents.

## Local Rules

- Treat this repository as public-facing. Example configs, docs, and fixtures
  must stay free of personal home paths, usernames, private repos, and other
  local-only values.
- Treat the shipped example config as a real runtime input. When config parsing
  or install behavior changes, test the copied default config through the actual
  install path, including fallback parser coverage and a no-network smoke path.
- Do not assume `npx skills add` copy or symlink behavior from help text alone.
  Probe it with a temporary `HOME` when wrapper behavior depends on where the
  canonical `~/.agents/skills` payload is created.
- Keep the wrapper responsible for the shared canonical layer and agent fanout
  symlinks. For local sources that must remain linked to a checkout, create the
  canonical symlink explicitly instead of relying on downstream CLI defaults.
