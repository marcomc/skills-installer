# Changelog

## Unreleased

## 0.1.0 - 2026-06-13

### Added

- Add `install_external_agent_skills.sh`.
- Add TOML-based external skills configuration.
- Add Makefile install, uninstall, lint, and validate targets.
- Add per-source `canonical_mode = "copy" | "symlink"` support.
- Document installer workflow and link topology with Mermaid diagrams.
- Add a no-network smoke test for symlink-mode planning and fanout.
- Document runtime requirements and script options.

### Fixed

- Stage copy-mode installs in a temporary HOME before copying skills into the
  canonical `~/.agents/skills` layer.
- Require agent fanout symlinks to point at the canonical layer instead of only
  resolving to the same final source path.
- Honor `XDG_CONFIG_HOME` in `make install`.
- Use neutral placeholder GitHub sources in shipped examples.
- Reject unsafe selected local skill names before using them as filesystem paths.
- Limit local tree traversal when `full_depth = false`.
- Preserve the previous canonical copy until replacement copy succeeds.
