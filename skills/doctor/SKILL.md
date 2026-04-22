---
name: doctor
description: Read-only health check for the obsidian-memory install — reports config, vault, dependency, and flag status with one-line remediation hints. Use when the user says "check obsidian-memory install", "is my obsidian-memory setup working", "diagnose obsidian-memory", "health check obsidian-memory", or invokes /obsidian-memory:doctor.
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: doctor

Run a one-command health check against the local obsidian-memory install and report whether every piece — config, vault, dependencies, and feature flags — is wired up correctly. Doctor is strictly a **reporter**: it inspects state and prints remediation hints, but it never mutates the config, the vault, or the `~/.claude/projects` symlink. Fixing is the job of `/obsidian-memory:setup`.

## When to Use

- Immediately after running `/obsidian-memory:setup` to confirm the install is healthy.
- When silent hook behavior is suspected ("my sessions don't seem to be distilling").
- Before filing a bug — the output pinpoints which component is broken.
- When ripping out and reinstalling the plugin, to verify the clean state.

## When NOT to Use

- To fix a broken install — use `/obsidian-memory:setup` or `/obsidian-memory:toggle`.
- To verify live RAG retrieval against an actual prompt — that is covered by the integration tests, not doctor.
- To inspect vault contents — doctor reports presence only, never reads note bodies.

## Invocation

```
/obsidian-memory:doctor         # human-readable report, ANSI-colored on TTY
/obsidian-memory:doctor --json  # machine-readable JSON report
```

## Behavior

1. Invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-doctor.sh"` with any arguments the user passed (e.g., `--json`), using `"$@"` so flags pass through verbatim.
2. Relay the script's stdout and exit code directly — do not re-interpret the results, do not re-run the script, and do not attempt to fix anything.
3. If the exit code is non-zero, call out the specific failing line(s) in a short summary ("RAG is disabled — run /obsidian-memory:toggle rag on") so the user doesn't have to re-read the full report.

The script itself is read-only: no `>`, `>>`, `mv`, `rm`, `ln`, or `mkdir` anywhere in its body. This is an enforced invariant — doctor would rather report `FAIL` than mutate state.

## Checks Performed

| Check | Status vocabulary | Remediation hint (on FAIL) |
|-------|-------------------|----------------------------|
| `config` | ok / fail | `run /obsidian-memory:setup <vault>` |
| `jq` | ok / fail | `brew install jq` |
| `vault_path` | ok / fail | `run /obsidian-memory:setup <vault>` |
| `claude` | ok / fail | `install the Claude Code CLI; see https://docs.claude.com/claude-code` |
| `sessions_dir` | ok / fail | `run /obsidian-memory:setup <vault>` |
| `projects_symlink` | ok / fail | `run /obsidian-memory:setup <vault>` |
| `rag_enabled` | ok / fail | `run /obsidian-memory:toggle rag on` |
| `distill_enabled` | ok / fail | `run /obsidian-memory:toggle distill on` |
| `scope_mode` | info | (informational; reports `projects.mode` and excluded/allowed counts — adjust with `/obsidian-memory:scope`) |
| `distill_template` | info | (informational; reports the active distillation template — `default (bundled)`, `global: <path>`, `project-override(<slug>): <path>`, or `configured but unreadable — falling back to default`. Configure via `distill.template_path` in `~/.claude/obsidian-memory/config.json`.) |
| `ripgrep` | info | (optional; vault-rag.sh falls back to POSIX `grep -r`) |
| `mcp` | info | (optional; Obsidian MCP server registration) |

## Idempotency

Safe to re-run indefinitely. Doctor performs no writes.

## Error handling

- If `jq` is missing, jq-dependent probes degrade to `FAIL: cannot check — …` with an actionable hint rather than crashing.
- If `claude mcp list` errors or times out (3 s cap when `timeout` is available), the MCP probe falls back to `INFO: mcp status unknown`.
- Any unexpected runtime failure trips the script's `ERR` trap and exits 1 — the skill relays that exit code.

## Related skills

- `/obsidian-memory:setup` writes the config, creates the sessions directory, and manages the projects symlink. Run it (or re-run it) when doctor reports any of those as `FAIL`.
- `/obsidian-memory:distill-session` checkpoints the newest transcript on demand. Doctor has no opinion on whether distillation itself succeeds — only on whether the prerequisites are in place.
