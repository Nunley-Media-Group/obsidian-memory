---
name: reindex
description: Build or rebuild the embeddings index under ~/.claude/obsidian-memory/index/ so the RAG hook's embedding backend can rank vault notes by semantic similarity. Use when the user says "rebuild embeddings index", "reindex obsidian memory", "reindex my vault", "build vault embeddings", "refresh embedding index", "ollama reindex", "rebuild vault index", "/obsidian-memory:doctor says index missing", "switch obsidian memory to embeddings", or invokes /obsidian-memory:reindex.
argument-hint: [--model <name>] [--endpoint <url>] [--quiet]
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: reindex

Rebuild the embeddings index at `~/.claude/obsidian-memory/index/embeddings.jsonl` so the RAG hook's opt-in embedding backend can score vault notes by semantic similarity via a local ollama daemon. Reindex is a **thin relayer**: every code path — config load, ollama reachability probe, per-note embedding, atomic commit, companion meta file, exit code — lives in `scripts/vault-reindex.sh`, which this skill invokes once and reports back verbatim. Unlike the silent hook scripts, reindex **surfaces failures loudly** — the user invoked it deliberately, so they need to see why the index didn't build.

## When to Use

- The user has just opted into the embedding backend (`rag.backend = "embedding"`) and needs the initial index built before the RAG hook can use it.
- The user added or rewrote many vault notes and wants the index to catch up — reindex is safe to re-run and rebuilds from scratch.
- The user changed `rag.embedding.model` and needs the index rebuilt at the new model's embedding dimension (old vectors are no longer compatible).
- `/obsidian-memory:doctor` reported the embedding-index probe as "index missing", "index stale", or "dim mismatch" and its remediation hint pointed here.
- The user wants to point the build at a non-default ollama endpoint or model for one run (`/obsidian-memory:reindex --endpoint http://remote:11434 --model mxbai-embed-large`) without editing config.

## When NOT to Use

- **When `rag.backend` is `"keyword"` (the default).** The keyword path never reads the index — running reindex is harmless but pointless. Flip the backend first if the user actually wants semantic retrieval.
- **From a hook or any hot path.** Reindex is synchronous and blocks on ollama; the `UserPromptSubmit` hook must never call it. The AC15 invariant ("hook never rebuilds the index on the hot path") depends on reindex staying a human-initiated surface.
- **To install or start ollama.** The script probes reachability and fails loudly if ollama is not running, but it never installs, `brew`s, or spawns the daemon. Getting ollama onto PATH and running `ollama serve` is the user's responsibility, documented in `steering/tech.md`.
- **For per-note incremental updates.** v1 rebuilds from scratch every run. Incremental indexing is a future enhancement — for now, full rebuild is the only path, and on ~1k-note vaults the wall time is dominated by ollama rather than file I/O.

## Invocation

```
/obsidian-memory:reindex                                          # build using config defaults
/obsidian-memory:reindex --model nomic-embed-text                 # override model for this run
/obsidian-memory:reindex --endpoint http://127.0.0.1:11434        # override endpoint for this run
/obsidian-memory:reindex --quiet                                  # suppress per-note progress
/obsidian-memory:reindex --model mxbai-embed-large --quiet        # overrides compose
```

`--model` and `--endpoint` are one-shot overrides — they do NOT rewrite `~/.claude/obsidian-memory/config.json`. The user's config defaults apply the next time reindex runs. `--quiet` drops per-note `[N/M] indexed: <rel>` lines but keeps the final summary so the user still sees the indexed count and final index path.

## Behavior

1. Invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-reindex.sh" "$@"` so arguments pass through verbatim.
2. Relay the script's stdout and exit code directly — do not re-interpret the results, do not re-run the script, and do not try to auto-fix failures (install ollama, pull a model, create the config, etc.). The script's error messages already carry the remediation hint.
3. On success the script prints a final summary line (`Indexed N/M note(s) -> <path> (model=… dim=…)`) and exits 0. If any note was skipped because it was empty, the script adds a second line (`Skipped N empty note(s).`) — this is still a success.
4. On failure the first stderr line begins with the literal `ERROR:` prefix, which makes the output grep-friendly for anyone scripting around it. Summarize that line back to the user in one sentence (e.g., "reindex failed: ollama unreachable at http://127.0.0.1:11434 — start the daemon with `ollama serve` and re-run") rather than letting the user re-read the whole transcript, but do NOT substitute your own interpretation for the script's message.

All logic — config load, endpoint probe, vault enumeration with exclusions (`.obsidian/**`, `.trash/**`, `claude-memory/projects/**`), per-note truncation to the first ~8 KB, ollama `POST /api/embeddings` request, cosine-dimension consistency check, atomic `.tmp` → `mv` commit, companion `embeddings.meta.json` write — lives in `scripts/vault-reindex.sh`. Keeping the SKILL body free of logic is what lets the bats and cucumber-shell tests exercise every path deterministically against a stub ollama without a live Claude session.

## Exit Code Contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Success — `embeddings.jsonl` and `embeddings.meta.json` were written atomically. The final summary line names the index path, model, and embedding dimension. |
| `1` | Runtime error — missing config, missing `jq` or `curl`, ollama unreachable, configured model not pulled, vault empty after exclusions, dimension mismatch mid-run, or the atomic write failed. The existing index on disk is untouched. |
| `2` | Bad usage — unknown flag, missing argument to `--model` / `--endpoint`. No read or write was attempted. |

The first line of stderr on any error always starts with the literal `ERROR:` prefix, which makes the output grep-friendly for anyone scripting around it.

## Error handling

- **Missing config** (`~/.claude/obsidian-memory/config.json` does not exist): the script prints `ERROR: config not found … — run /obsidian-memory:setup <vault> first` and exits 1. Reindex will not create a config — that is `/obsidian-memory:setup`'s job.
- **Missing `jq` or `curl`**: exits 1 with an install hint. Both are hard prerequisites — `jq` builds the JSON body and parses the response; `curl` talks to ollama. Without them the script cannot function.
- **ollama unreachable**: the script probes the endpoint with a short-timeout `curl` before starting the walk. If the daemon is down, it exits 1 with `ollama unreachable at <endpoint> — start the daemon (ollama serve) and try again`. No partial index is written.
- **Model not pulled**: if ollama returns an error body (no `.embedding` field), the script surfaces the ollama error message and exits 1. Remediation: `ollama pull <model>`.
- **Dimension mismatch mid-run**: if a later response returns a different embedding size than the first, the script aborts with `dimension mismatch on <rel>: got <new>, expected <first>` and exits 1 without committing. This guards against a mid-run model swap corrupting the index.
- **Empty vault** (no `*.md` files survive the exclusions): exits 1 with `no .md notes found under <vault> (after exclusions)`. An empty index is not a useful index.
- **Atomic-write failure** (disk full, permissions): the `.tmp` files in the index directory are cleaned by the `EXIT` trap; the existing `embeddings.jsonl` on disk is never truncated or half-written.

## Idempotency

Reindex is idempotent by construction:

- Re-running against an unchanged vault produces an index that is semantically equivalent to the previous one (row order follows vault traversal order; scores are deterministic given the same model). The file may differ bit-for-bit because of timestamps in `embeddings.meta.json.built_at`, but that's metadata, not content.
- The mutation path builds a temp file under `~/.claude/obsidian-memory/index/`, then `mv`s it into place — an interrupted reindex (up to and including SIGKILL between the per-note loop and the rename) leaves the original `embeddings.jsonl` intact rather than corrupted. Concurrent hot-path reads either see the old index or the new one, never a half-written one (AC15).
- `--quiet` does not change the on-disk outcome, only the operator-visible progress stream.
- `--model` / `--endpoint` overrides are one-shot — the config on disk is not rewritten, so the next run reverts to the config defaults.

## Related skills

- `/obsidian-memory:setup` writes the initial `~/.claude/obsidian-memory/config.json` that reindex reads. Reindex's "config not found" error points the user back to setup; there is no auto-creation path. Setup also documents the `rag.backend`, `rag.embedding.endpoint`, `rag.embedding.model`, and `rag.top_k` keys reindex honors.
- `/obsidian-memory:doctor` diagnoses the install read-only. When its embedding-backend probe reports `index missing`, `index stale`, or `dim mismatch`, its remediation hint is exactly `run /obsidian-memory:reindex` — the two skills are deliberately wired together.
- `/obsidian-memory:toggle` flips the `rag.enabled` / `distill.enabled` booleans. It does NOT touch `rag.backend` — switching between keyword and embedding retrieval is still a hand-edit of the config (or a future dedicated skill). Toggling `rag.enabled = false` disables the hook entirely; the index on disk is unaffected.
