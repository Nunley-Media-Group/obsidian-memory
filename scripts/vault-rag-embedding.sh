#!/usr/bin/env bash
# vault-rag-embedding.sh — embedding-retrieval backend for vault-rag.sh.
#
# Reads a hook JSON payload on stdin, POSTs the prompt to ollama for an
# embedding vector, scores every indexed note by cosine similarity in awk,
# and emits a <vault-context> block ranked by semantic relevance.
#
# Controlled fallback: any prerequisite failure (curl missing, ollama
# unreachable, malformed response, missing/corrupt index) exits non-zero
# with one stderr line — the dispatcher (vault-rag.sh) catches that and
# falls through to the keyword backend. Never interpolates prompt content
# into an argv; the prompt travels via curl --data @- as a JSON body read
# from stdin.

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
om_load_config rag

log_err() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }

# Override _common.sh's exit-0 ERR trap: an unexpected failure in the embedding
# path should signal fallback to the dispatcher, not a silent success.
trap 'log_err "failed at line $LINENO"; exit 1' ERR

PAYLOAD="$(om_read_payload)" || { log_err "empty payload"; exit 1; }
PROMPT="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || { log_err "empty prompt"; exit 1; }

# --- Preconditions -----------------------------------------------------------

command -v curl >/dev/null 2>&1 || { log_err "curl missing"; exit 1; }

ENDPOINT="$(jq -r '.rag.embedding.endpoint // "http://127.0.0.1:11434"' "$CONFIG" 2>/dev/null)"
MODEL="$(jq -r '.rag.embedding.model // "nomic-embed-text"' "$CONFIG" 2>/dev/null)"

# Warn on non-loopback endpoints so operators notice data is leaving the host.
case "$ENDPOINT" in
  http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*) ;;
  *) log_err "non-loopback embedding endpoint: $ENDPOINT" ;;
esac

TOP_K_RAW="$(jq -r '.rag.top_k // 5' "$CONFIG" 2>/dev/null)"
TOP_K="$TOP_K_RAW"
if ! printf '%s' "$TOP_K" | grep -qE '^[0-9]+$' || [ "$TOP_K" -lt 1 ] || [ "$TOP_K" -gt 50 ]; then
  log_err "rag.top_k=$TOP_K_RAW out of range; clamping to 5"
  TOP_K=5
fi

INDEX_DIR="$HOME/.claude/obsidian-memory/index"
INDEX_FILE="$INDEX_DIR/embeddings.jsonl"

if [ ! -f "$INDEX_FILE" ]; then
  log_err "index missing — run /obsidian-memory:reindex"
  exit 1
fi
if [ ! -s "$INDEX_FILE" ]; then
  log_err "index empty — run /obsidian-memory:reindex"
  exit 1
fi

# --- Scratch files + cleanup -------------------------------------------------

TMP_RESP="$(mktemp "${TMPDIR:-/tmp}/vault-rag-embed-resp.XXXXXX")"
TMP_IDX="$(mktemp "${TMPDIR:-/tmp}/vault-rag-embed-idx.XXXXXX")"
TMP_RANK="$(mktemp "${TMPDIR:-/tmp}/vault-rag-embed-rank.XXXXXX")"
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/vault-rag-embed-out.XXXXXX")"

# shellcheck disable=SC2329  # invoked indirectly by the EXIT/ERR traps
cleanup_embed() {
  rm -f "$TMP_RESP" "$TMP_IDX" "$TMP_RANK" "$TMP_OUT" 2>/dev/null
}
trap 'cleanup_embed; log_err "failed at line $LINENO"; exit 1' ERR
trap 'cleanup_embed' EXIT

# --- Embed the prompt --------------------------------------------------------

REQ_BODY="$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p}')"

HTTP_CODE="$(
  printf '%s' "$REQ_BODY" \
    | curl -sS --max-time 5 -o "$TMP_RESP" -w '%{http_code}' \
        -X POST "$ENDPOINT/api/embeddings" \
        -H 'content-type: application/json' \
        --data @- 2>/dev/null
)" || { log_err "ollama unreachable at $ENDPOINT"; exit 1; }

case "$HTTP_CODE" in
  2??) ;;
  *) log_err "ollama HTTP $HTTP_CODE at $ENDPOINT"; exit 1 ;;
esac

QVEC="$(jq -r 'if (.embedding // empty | type) == "array" then .embedding | join(" ") else empty end' "$TMP_RESP" 2>/dev/null)"
if [ -z "$QVEC" ]; then
  log_err "model $MODEL missing or response has no embedding"
  exit 1
fi
export QVEC

# --- Score the index ---------------------------------------------------------

# Index JSONL → "rel<TAB>f1 f2 f3 ...<TAB>abs-path" for awk.
if ! jq -r 'select(.embedding and (.embedding | type == "array")) | "\(.rel // .path // "")\t\(.embedding | join(" "))\t\(.path // "")"' \
        "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null; then
  log_err "index corrupt"
  exit 1
fi
[ -s "$TMP_IDX" ] || { log_err "index empty after parse"; exit 1; }

# Cosine similarity. $1=rel, $2=embedding, $3=abs path. QVEC env var supplies
# the query vector as space-separated floats; rows whose dim doesn't match are
# skipped (handles model upgrades that changed embedding size).
awk -F'\t' '
BEGIN {
  n = split(ENVIRON["QVEC"], q, " ")
  qnorm = 0
  for (i = 1; i <= n; i++) qnorm += q[i] * q[i]
  qnorm = sqrt(qnorm)
}
{
  m = split($2, v, " ")
  if (m != n) next
  dot = 0; norm = 0
  for (i = 1; i <= n; i++) { dot += q[i] * v[i]; norm += v[i] * v[i] }
  score = (qnorm > 0 && norm > 0) ? dot / (qnorm * sqrt(norm)) : 0
  printf "%.6f\t%s\t%s\n", score, $1, $3
}' "$TMP_IDX" \
  | sort -rn -k1,1 \
  | head -n "$TOP_K" \
  > "$TMP_RANK"

[ -s "$TMP_RANK" ] || { log_err "no ranked results"; exit 1; }

# --- Build output in a buffer so a mid-emit failure can't leak a partial block

{
  printf '<vault-context source="obsidian" backend="embedding" model="%s">\n' "$MODEL"
  while IFS=$'\t' read -r score rel path; do
    [ -n "$rel" ] || continue
    printf '\n### %s  (score: %s)\n' "$rel" "$score"
    excerpt=""
    if [ -n "$path" ] && [ -f "$path" ]; then
      excerpt="$(head -c 600 "$path" 2>/dev/null)"
    elif [ -f "$VAULT/$rel" ]; then
      excerpt="$(head -c 600 "$VAULT/$rel" 2>/dev/null)"
    fi
    if [ -n "$excerpt" ]; then
      # shellcheck disable=SC2016
      printf '```\n%s\n```\n' "$excerpt"
    fi
  done < "$TMP_RANK"
  printf '</vault-context>\n'
} > "$TMP_OUT"

cat "$TMP_OUT"
exit 0
