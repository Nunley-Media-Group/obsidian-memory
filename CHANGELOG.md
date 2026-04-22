# Changelog

All notable changes to plugins in this marketplace are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this repo uses [Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

## [0.2.0] - 2026-04-21

### Added

- `/obsidian-memory:doctor` skill — on-demand health check that surfaces silent install failures without mutating any state. Reports `OK`/`FAIL` per check (config presence, vault path, `jq`/`claude`/`ripgrep` on PATH, `claude-memory/sessions/` directory, `claude-memory/projects` symlink, `rag.enabled`/`distill.enabled` flags) with one-line remediation hints. Exits 0 if all checks pass, non-zero on any failure. Supports `--json` for machine-readable output.

## [0.1.0] - 2026-04-21

### Added

- **obsidian-memory 0.1.0** — new plugin providing automatic, Obsidian-backed cross-session memory for Claude Code.
  - `UserPromptSubmit` hook (`vault-rag.sh`): keyword-RAG over the user's Obsidian vault; injects a `<vault-context>` block on every prompt. Falls back from `ripgrep` to POSIX `grep`/`find` when `rg` is unavailable. Excludes `claude-memory/projects/**` to prevent a transcript feedback loop.
  - `SessionEnd` hook (`vault-distill.sh`): distills the session transcript via nested `CLAUDECODE="" claude -p` into a dated note under `<vault>/claude-memory/sessions/<project-slug>/` and links it from `Index.md`.
  - `/obsidian-memory:setup <vault-path>` skill — idempotent one-time setup: writes `~/.claude/obsidian-memory/config.json`, symlinks the auto-memory projects folder into the vault, initializes the index, and optionally registers the Obsidian MCP server at user scope.
  - `/obsidian-memory:distill-session` skill — manual mid-session checkpoint counterpart to the `SessionEnd` hook.
  - Installed at user scope; every hook silently no-ops (exit 0) on missing dep, missing config, disabled flag, or empty input.
