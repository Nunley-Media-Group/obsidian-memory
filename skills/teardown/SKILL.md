---
name: teardown
description: Inverse of /obsidian-memory:setup — safely removes the config file and projects symlink, optionally purges distilled session notes behind a typed-"yes" prompt, and optionally unregisters the Obsidian MCP server. Use when the user says "uninstall obsidian memory", "remove obsidian-memory", "tear down obsidian memory", "undo obsidian-memory setup", "reverse obsidian-memory setup", "clean up obsidian-memory", "inverse of setup", or invokes /obsidian-memory:teardown.
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: teardown

Cleanly reverse the filesystem footprint written by `/obsidian-memory:setup`. Teardown is a **thin relayer**: every check and every deletion lives in `scripts/vault-teardown.sh`, which Claude invokes once and reports back verbatim. The script's default behavior is the safe behavior — it removes the plugin's own config and the `<vault>/claude-memory/projects` symlink, and it **preserves distilled session notes** unless the user explicitly asks for them to be purged and confirms at a typed-`yes` prompt.

## When to Use

- The user wants to uninstall the plugin's footprint (e.g., before switching vaults, before filing a reproducible bug, or before removing the plugin entirely with `claude plugin uninstall`).
- The user wants to reverse what `/obsidian-memory:setup` wrote without hand-tracing every path.
- The user is migrating to a new vault and wants the old vault's `claude-memory/` symlink and the stale `config.json` gone.
- The user wants to unregister the Obsidian MCP server as part of a cleanup (`--unregister-mcp`).
- The user wants to preview what would be removed before acting (`--dry-run`).

## When NOT to Use

- **To uninstall the plugin itself.** Teardown removes *setup's footprint*, not the plugin package. Uninstalling the plugin is `claude plugin uninstall obsidian-memory` and is outside this skill's scope.
- **To migrate distilled notes to a new vault.** Teardown deletes or preserves; it does not copy. If the user wants to keep the notes, they should either run default teardown (which preserves them in place) and manually move `<vault>/claude-memory/sessions/` / `Index.md` to the new vault, or set up against the new vault first and then run teardown against the old one.
- **To delete the vault itself.** Teardown only touches `<vault>/claude-memory/` and `~/.claude/obsidian-memory/`. The vault directory is user-owned and never removed.
- **To recover from a bad config without understanding why.** If `/obsidian-memory:doctor` reports failures, run doctor first and read the diagnosis — teardown's refusal path deliberately points the user there rather than guessing.

## Invocation

```
/obsidian-memory:teardown                       # default: remove config + symlink; preserve sessions + Index.md
/obsidian-memory:teardown --purge               # also delete sessions/ and Index.md after typed "yes"
/obsidian-memory:teardown --unregister-mcp      # also best-effort `claude mcp remove obsidian -s user`
/obsidian-memory:teardown --dry-run             # print the plan; touch nothing; never prompt
/obsidian-memory:teardown --purge --dry-run     # plan includes sessions under WOULD REMOVE; still no prompt
```

Flags combine freely. `--dry-run` suppresses every side effect, including the MCP command.

## Behavior

1. Invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-teardown.sh"` with any arguments the user passed, using `"$@"` so every flag passes through verbatim.
2. Relay the script's stdout and exit code directly — do not re-interpret the results, do not attempt to fix the refusal, and **never call the script twice in one invocation**. A second call after a successful run would hit the idempotent "nothing to do" path; a second call after a refusal would still refuse.
3. If the exit code is non-zero, call out the specific reason in a short summary (for example, "teardown refused: projects symlink points at an unrelated path — run `/obsidian-memory:doctor` to diagnose") so the user does not have to re-read the full report.

## Flag Reference

| Flag | Effect |
|------|--------|
| *(none)* | Remove `~/.claude/obsidian-memory/config.json` and the `<vault>/claude-memory/projects` symlink. Preserve `sessions/` and `Index.md`. Leave the MCP registration alone. |
| `--purge` | On top of the default removals, delete `<vault>/claude-memory/sessions/` and `<vault>/claude-memory/Index.md` **after the user types the literal string `yes`** at the confirmation prompt. Any other response cancels the purge. |
| `--unregister-mcp` | On top of the default removals, best-effort run `timeout 3 claude mcp remove obsidian -s user`. A non-zero exit, a timeout, or a missing `claude` binary is reported as a one-line non-fatal warning — teardown still exits 0. |
| `--dry-run` | Print the plan with `WOULD REMOVE:` / `WOULD PRESERVE:` labels and exit 0 without touching anything. Combines with every other flag: `--dry-run --purge` lists `sessions/` and `Index.md` under WOULD REMOVE without prompting; `--dry-run --unregister-mcp` does **not** invoke `claude mcp remove`. |
| *any unknown flag* | Print a usage line to stderr and exit 2. |

## Safety Guarantees

These are the load-bearing invariants teardown enforces. Both the skill and the underlying script exist to preserve them.

### Distilled notes are the user's memory

The default run **never deletes** `<vault>/claude-memory/sessions/` or `<vault>/claude-memory/Index.md`. Purging requires both `--purge` *and* the user typing the exact literal string `yes` at the confirmation prompt. The prompt is case-sensitive: `y`, `Y`, `YES`, an empty line, or EOF on stdin all cancel the purge and preserve the notes. There is deliberately **no `-y` / `--yes` override** — anyone who genuinely needs unattended purge can delete the plain-Markdown note files directly.

`--purge` is destructive and not reversible. Distilled notes are ordinary Markdown under the vault — if the user prefers to pick and choose which sessions to keep, they can delete files manually and re-run teardown without `--purge`.

### Path-safety gate

Before any deletion runs, the script validates the layout at the configured vault path:

- The configured vault must exist and be a directory.
- `<vault>/claude-memory/` must exist and be a directory.
- `<vault>/claude-memory/projects` must be either **absent** or a symlink that resolves (via plain `readlink`, no `-f`) to `$HOME/.claude/projects`.

If any check fails, the script prints `REFUSED`, the detected vault path, the specific mismatch, and a hint pointing at `/obsidian-memory:doctor` for diagnosis — and exits non-zero **without deleting anything**. This catches the "user edited `config.json` to point at an unrelated directory" class of accident.

### Idempotent

Running teardown on an already-torn-down install is a no-op: if `~/.claude/obsidian-memory/config.json` is absent, the script prints "nothing to do" and exits 0 without touching the filesystem. Safe to re-run.

## Exit Code Contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Success — includes a completed teardown, a cancelled purge, the idempotent nothing-to-do path, and every `--dry-run` invocation. |
| `1` | Path-safety refusal — the layout at the configured vault does not match setup's footprint. Nothing was deleted. Run `/obsidian-memory:doctor` and reconcile. |
| `2` | Bad usage — an unknown flag was passed. |

## Error handling

- **Missing `jq`**: required to read `vaultPath` from the config. The script treats this as a path-safety refusal (exit 1) with a hint to install `jq` — it will not guess at the vault path from another source.
- **Missing `claude` on PATH** (only meaningful with `--unregister-mcp`): the MCP unregistration step prints a one-line non-fatal warning and the rest of the teardown still completes. Exit code stays 0.
- **`claude mcp remove` exits non-zero or times out**: same non-fatal treatment — a one-line warning, teardown exit code stays 0.
- **Non-interactive `--purge`** (stdin is not a TTY, e.g., piped from a script): the confirmation prompt reads EOF and cancels the purge. This is the correct failsafe; sessions are preserved.

## Idempotency

Teardown is idempotent by construction. Running it a second time after a successful run lands on the "no config found — nothing to do" branch and makes no filesystem changes. Running it against an already-partial install (e.g., symlink gone, config still present) still works: the script composes its plan against the state it finds, not against a rigid expected-shape.

## Related skills

- `/obsidian-memory:setup` wrote the footprint that teardown reverses. Re-run setup against a different vault path to "migrate" without losing the current config first.
- `/obsidian-memory:doctor` diagnoses the install state read-only. Teardown's path-safety refusal message explicitly routes the user here: if the layout does not match what setup would have produced, doctor's per-check output identifies exactly which piece has drifted so the user can reconcile manually before re-running teardown.
- `/obsidian-memory:distill-session` writes into `<vault>/claude-memory/sessions/`. If the user just wants to stop distilling without removing the config, running teardown is overkill — toggle the `distill` feature off instead.
