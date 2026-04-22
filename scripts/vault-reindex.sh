#!/usr/bin/env bash
# vault-reindex.sh — build or rebuild the embeddings index at
# ~/.claude/obsidian-memory/index/embeddings.jsonl.
#
# User-invoked (unlike the silent hook scripts) — errors surface on stderr
# with non-zero exit so the user knows why it failed. Reads every *.md under
# $VAULT (applying the same exclusions as vault-rag-keyword.sh), truncates
# each to the first ~8 KB, POSTs to ollama's /api/embeddings, and writes the
# index atomically via a temp file + mv.
#
# Exit codes:
#   0 — success (all reachable notes indexed, embeddings.jsonl + meta written)
#   1 — configuration or daemon failure (missing config, jq, curl; ollama
#       unreachable; model missing; vault missing; atomic write failed)
#   2 — bad usage

set -u

CONFIG="${HOME}/.claude/obsidian-memory/config.json"
INDEX_DIR="$HOME/.claude/obsidian-memory/index"
INDEX_FILE="$INDEX_DIR/embeddings.jsonl"
META_FILE="$INDEX_DIR/embeddings.meta.json"

TMP_INDEX=""
TMP_META=""
MAX_BYTES=8192

log_err() { printf 'ERROR: %s\n' "$*" >&2; }
log_info() { [ "${QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }

# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap
cleanup() {
  [ -n "$TMP_INDEX" ] && rm -f "$TMP_INDEX" 2>/dev/null
  [ -n "$TMP_META" ] && rm -f "$TMP_META" 2>/dev/null
}
trap cleanup EXIT
trap 'log_err "failed at line $LINENO"; exit 1' ERR

usage_stderr() {
  cat >&2 <<'USAGE'
Usage: vault-reindex.sh [--model <name>] [--endpoint <url>] [--quiet]

Rebuilds the embeddings index at ~/.claude/obsidian-memory/index/embeddings.jsonl.
Requires `curl`, `jq`, and a reachable ollama daemon with the configured model.

Options:
  --model <name>     Override rag.embedding.model for this build.
  --endpoint <url>   Override rag.embedding.endpoint for this build.
  --quiet            Suppress per-note progress; keep only the final summary.
USAGE
}

# --- Parse args --------------------------------------------------------------

MODEL_OVERRIDE=""
ENDPOINT_OVERRIDE=""
QUIET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ "$#" -ge 2 ] || { usage_stderr; exit 2; }
      MODEL_OVERRIDE="$2"
      shift 2
      ;;
    --endpoint)
      [ "$#" -ge 2 ] || { usage_stderr; exit 2; }
      ENDPOINT_OVERRIDE="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage_stderr
      exit 0
      ;;
    *)
      log_err "unknown argument: $1"
      usage_stderr
      exit 2
      ;;
  esac
done

# --- Preconditions -----------------------------------------------------------

command -v jq >/dev/null 2>&1 || { log_err "jq missing — install jq (brew install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { log_err "curl missing — install curl"; exit 1; }

if [ ! -r "$CONFIG" ]; then
  log_err "config not found at $CONFIG — run /obsidian-memory:setup <vault> first"
  exit 1
fi

VAULT="$(jq -r '.vaultPath // ""' "$CONFIG" 2>/dev/null)"
[ -n "$VAULT" ] || { log_err "vaultPath missing from config — run /obsidian-memory:setup <vault>"; exit 1; }
[ -d "$VAULT" ] || { log_err "vault directory does not exist: $VAULT"; exit 1; }

ENDPOINT="${ENDPOINT_OVERRIDE:-$(jq -r '.rag.embedding.endpoint // "http://127.0.0.1:11434"' "$CONFIG" 2>/dev/null)}"
MODEL="${MODEL_OVERRIDE:-$(jq -r '.rag.embedding.model // "nomic-embed-text"' "$CONFIG" 2>/dev/null)}"

log_info "endpoint: $ENDPOINT"
log_info "model:    $MODEL"
log_info "vault:    $VAULT"

# Probe ollama reachability with a HEAD/GET to the root.
if ! curl -sS --max-time 5 -o /dev/null "$ENDPOINT/" 2>/dev/null; then
  log_err "ollama unreachable at $ENDPOINT — start the daemon (ollama serve) and try again"
  exit 1
fi

# --- Enumerate vault notes ---------------------------------------------------

mkdir -p "$INDEX_DIR" || { log_err "cannot create $INDEX_DIR"; exit 1; }

TMP_INDEX="$(mktemp "$INDEX_DIR/embeddings.jsonl.XXXXXX")"
TMP_META="$(mktemp "$INDEX_DIR/embeddings.meta.json.XXXXXX")"

# Use the same exclusion rules as vault-rag-keyword.sh: skip .obsidian/**,
# .trash/**, and claude-memory/projects/** (the auto-memory symlink).
NOTES_LIST="$(mktemp "${TMPDIR:-/tmp}/vault-reindex-notes.XXXXXX")"
# shellcheck disable=SC2064  # NOTES_LIST value frozen at trap install time
trap "rm -f \"$NOTES_LIST\"; cleanup" EXIT

find "$VAULT" \
    \( -path "$VAULT/.obsidian" \
       -o -path "$VAULT/.trash" \
       -o -path "$VAULT/claude-memory/projects" \) -prune \
    -o -type f -name '*.md' -print \
  > "$NOTES_LIST" 2>/dev/null

TOTAL="$(wc -l < "$NOTES_LIST" | tr -d '[:space:]')"

if [ "$TOTAL" -eq 0 ]; then
  log_err "no .md notes found under $VAULT (after exclusions)"
  exit 1
fi

log_info "indexing $TOTAL note(s) from $VAULT"

# --- Embed each note ---------------------------------------------------------

# Dimension is captured from the first successful embedding and asserted
# consistent across the rest (so a mid-run model swap doesn't corrupt the index).
DIM=""
INDEXED=0
SKIPPED=0
PROGRESS=0

while IFS= read -r note_path; do
  [ -n "$note_path" ] || continue
  PROGRESS=$((PROGRESS + 1))

  rel="${note_path#"$VAULT"/}"
  content="$(head -c "$MAX_BYTES" "$note_path" 2>/dev/null)"
  if [ -z "$content" ]; then
    SKIPPED=$((SKIPPED + 1))
    log_info "[$PROGRESS/$TOTAL] skip (empty): $rel"
    continue
  fi

  req_body="$(jq -n --arg m "$MODEL" --arg p "$content" '{model: $m, prompt: $p}')"
  resp="$(
    printf '%s' "$req_body" \
      | curl -sS --max-time 30 -X POST "$ENDPOINT/api/embeddings" \
          -H 'content-type: application/json' \
          --data @- 2>/dev/null
  )" || {
    log_err "ollama request failed for $rel"
    exit 1
  }

  vec="$(printf '%s' "$resp" | jq -c '.embedding // empty' 2>/dev/null)"
  if [ -z "$vec" ] || [ "$vec" = "null" ]; then
    err_msg="$(printf '%s' "$resp" | jq -r '.error // ""' 2>/dev/null)"
    if [ -n "$err_msg" ]; then
      log_err "ollama error: $err_msg (model=$MODEL)"
    else
      log_err "ollama returned no embedding for $rel (is model \"$MODEL\" pulled?)"
    fi
    exit 1
  fi

  this_dim="$(printf '%s' "$vec" | jq 'length' 2>/dev/null)"
  if [ -z "$DIM" ]; then
    DIM="$this_dim"
  elif [ "$this_dim" != "$DIM" ]; then
    log_err "dimension mismatch on $rel: got $this_dim, expected $DIM"
    exit 1
  fi

  mtime="$(stat -f '%m' "$note_path" 2>/dev/null || stat -c '%Y' "$note_path" 2>/dev/null || printf '0')"

  jq -c -n \
    --arg path "$note_path" \
    --arg rel "$rel" \
    --argjson embedding "$vec" \
    --argjson mtime "$mtime" \
    --arg model "$MODEL" \
    --argjson dim "$this_dim" \
    '{path: $path, rel: $rel, embedding: $embedding, mtime: $mtime, model: $model, dim: $dim}' \
    >> "$TMP_INDEX"

  INDEXED=$((INDEXED + 1))
  log_info "[$PROGRESS/$TOTAL] indexed: $rel"
done < "$NOTES_LIST"

if [ "$INDEXED" -eq 0 ]; then
  log_err "no notes indexed (every note was empty or errored)"
  exit 1
fi

# --- Atomic commit -----------------------------------------------------------

built_at="$(date +%s)"
jq -n \
  --argjson built_at "$built_at" \
  --arg vault_path "$VAULT" \
  --argjson note_count "$INDEXED" \
  --arg model "$MODEL" \
  --argjson dim "${DIM:-0}" \
  '{built_at: $built_at, vault_path: $vault_path, note_count: $note_count, model: $model, dim: $dim}' \
  > "$TMP_META"

mv "$TMP_INDEX" "$INDEX_FILE" || { log_err "atomic write failed: $INDEX_FILE"; exit 1; }
TMP_INDEX=""
mv "$TMP_META" "$META_FILE" || { log_err "atomic write failed: $META_FILE"; exit 1; }
TMP_META=""

printf 'Indexed %d/%d note(s) -> %s (model=%s dim=%s)\n' \
  "$INDEXED" "$TOTAL" "$INDEX_FILE" "$MODEL" "${DIM:-0}"
[ "$SKIPPED" -eq 0 ] || printf 'Skipped %d empty note(s).\n' "$SKIPPED"

exit 0
