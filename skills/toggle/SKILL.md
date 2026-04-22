---
name: toggle
description: Flip rag.enabled / distill.enabled in obsidian-memory's config without hand-editing JSON. Use when the user says "disable rag", "enable distill", "turn off obsidian memory hook", "toggle rag", "toggle distill", "stop distilling sessions", "pause obsidian memory", or invokes /obsidian-memory:toggle.
argument-hint: [<feature> [<state>]]
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: toggle

Flip the `rag.enabled` / `distill.enabled` booleans in `~/.claude/obsidian-memory/config.json` with a single command, preserving every other key in the file. Toggle is a **thin relayer**: every code path — arg parsing, feature whitelist, atomic write, exit code selection — lives in `scripts/vault-toggle.sh`, which this skill invokes once and reports back verbatim. The usual loop of "open the config, flip a boolean, save" collapses into one invocation the user can type while they're already in the middle of debugging a hook.

## When to Use

- The user wants to disable RAG injection for a session (`/obsidian-memory:toggle rag off`).
- Distillation is misbehaving and the user wants to stop writing to the vault while they investigate (`/obsidian-memory:toggle distill off`).
- The user wants to confirm whether a surprising behavior originates from obsidian-memory by temporarily turning a hook off, then on again.
- `/obsidian-memory:doctor` reported `rag.enabled` or `distill.enabled` as `FAIL` and its remediation hint pointed here.
- The user asks for the current state of both flags without changing anything (`/obsidian-memory:toggle` or `/obsidian-memory:toggle status`).

## When NOT to Use

- **To write the config from scratch.** Toggle requires a config produced by `/obsidian-memory:setup`; a missing config is a clean error with a setup hint, not a silent create.
- **To change any key other than `rag.enabled` or `distill.enabled`.** The feature whitelist is hard-coded to those two. Editing `vaultPath` or any other key is still a hand-edit job (or a new skill).
- **To skip distillation for one specific session.** If the user only wants to opt out of a single distill, `/obsidian-memory:distill-session` is the alternate manual entry point — flipping `distill.enabled` is heavier than needed.
- **To uninstall the plugin's footprint.** Removing the config and the `<vault>/claude-memory/projects` symlink is `/obsidian-memory:teardown`'s job.

## Invocation

```
/obsidian-memory:toggle                      # status — prints both flags, mutates nothing
/obsidian-memory:toggle status               # same as above, explicit
/obsidian-memory:toggle rag                  # flip current rag.enabled
/obsidian-memory:toggle rag off              # set rag.enabled = false
/obsidian-memory:toggle distill on           # set distill.enabled = true
```

`<feature>` is exactly `rag` or `distill`. `<state>` is case-insensitive and accepts the aliases `on` / `off`, `true` / `false`, `1` / `0`, `yes` / `no` — this way the user's muscle memory works whether they think in CLI-isms (`on`/`off`) or JSON-isms (`true`/`false`).

## Behavior

1. Invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-toggle.sh" "$@"` so every argument passes through verbatim. Do not re-parse the arguments and do not re-run the script.
2. Relay the script's stdout and exit code directly. If the script exits non-zero, summarize the specific reason in one line (e.g., "toggle failed: config not found — run `/obsidian-memory:setup <vault>` first") so the user does not have to re-read the full output, but never substitute your own interpretation for the script's message.
3. On a successful mutation the script prints `<feature>.enabled: <prev> -> <new>` on stdout. On an already-in-state call it prints `<feature>.enabled was already <value>` — this is still a success and exits 0. On a status read it prints both flags on two lines.

All logic — argument parsing, feature whitelist, alias resolution, atomic write, "was already" no-op detection — lives in `scripts/vault-toggle.sh`. Keeping the SKILL body free of logic is what lets the bats and cucumber-shell tests exercise every path deterministically without a live Claude session.

## Exit Code Contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Success — includes a status read, a successful mutation, and the "was already in that state" no-op. |
| `1` | Runtime error — config missing, config unreadable, `jq` missing, or the atomic write failed. The config on disk is unchanged. |
| `2` | Bad usage — unknown feature, unknown state alias, or too many arguments. No read or write was attempted. |

The first line of stderr on any error always starts with the literal `ERROR:` prefix, which makes the output grep-friendly for anyone scripting around it.

## Error handling

- **Missing config** (`~/.claude/obsidian-memory/config.json` does not exist): the script prints `ERROR: config not found — run /obsidian-memory:setup <vault> first` to stderr and exits 1. Nothing is created under `~/.claude/obsidian-memory/` — re-running `/obsidian-memory:setup` is the only way forward.
- **Missing `jq`**: exits 1 with an install hint (`brew install jq`). Toggle will not attempt a write without `jq` because the atomic-write guarantee depends on it.
- **Unknown feature or state alias**: exits 2 with a usage line naming the allowed values. The config is untouched (neither read for content nor rewritten).
- **Failed write** (rare — out of disk, permissions, or a concurrent process holding the path): the atomic-write idiom guarantees the original config is never truncated or partially overwritten. The script exits 1; an `EXIT` trap clears any stray `.tmp.$$` artifact from the config directory.

## Idempotency

Toggle is idempotent by construction:

- Running `/obsidian-memory:toggle rag on` against a config where `rag.enabled` is already `true` is a no-op — the script prints `rag.enabled was already true` and exits 0 **without rewriting the file** (so `mtime` and inode are preserved; downstream tools watching the config for changes stay quiet).
- `/obsidian-memory:toggle status` and the no-arg invocation never write, so they're safe to run in a loop (e.g., from a `watch` command or a health check).
- The mutation path writes to a temp file in the same directory as the config, then `mv`s it into place — an interrupted toggle (up to and including SIGKILL between the write and the rename) leaves the original config intact rather than corrupted.

## Related skills

- `/obsidian-memory:setup` writes the initial `~/.claude/obsidian-memory/config.json` that toggle reads and mutates. Toggle's "config not found" error points the user back to setup; there is no auto-creation path.
- `/obsidian-memory:doctor` diagnoses the install read-only. When its `rag_enabled` or `distill_enabled` probe reports `FAIL`, its remediation hint is exactly `run /obsidian-memory:toggle <feature> on` — the two skills are deliberately wired together.
- `/obsidian-memory:distill-session` manually checkpoints the newest transcript. If the user only wants to skip distilling one specific session rather than disable the hook for every future session, running `distill-session` against the desired session (or simply not running it) is lighter than flipping the global flag.
