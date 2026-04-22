#!/usr/bin/env bash
# vault-rag.sh — UserPromptSubmit hook (dispatcher).
#
# Preserves v0.1 guards (jq, config, rag.enabled, vault dir), reads the
# rag.backend config key, and delegates to the matching backend script:
#
#   "keyword"   → scripts/vault-rag-keyword.sh   (v0.1 behavior, the default)
#   "embedding" → scripts/vault-rag-embedding.sh (opt-in, falls back on failure)
#   <other>     → keyword, with a stderr warning
#
# hooks/hooks.json is unchanged — this is the load-bearing "one-script swap"
# invariant (FR17). Stdin is teed to a mktemp scratch file so the fallback
# branch can replay the payload into the keyword backend.

# shellcheck source=scripts/_common.sh
SCRIPT_DIR="$(dirname "$0")"
. "$SCRIPT_DIR/_common.sh"
om_load_config rag

log_err() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }

PAYLOAD="$(om_read_payload)" || exit 0

PAYLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/vault-rag-payload.XXXXXX")"
trap 'rm -f "$PAYLOAD_TMP" 2>/dev/null; exit 0' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_TMP"

BACKEND="$(jq -r '.rag.backend // "keyword"' "$CONFIG" 2>/dev/null)"

case "$BACKEND" in
  keyword)
    "$SCRIPT_DIR/vault-rag-keyword.sh" < "$PAYLOAD_TMP"
    ;;
  embedding)
    if ! "$SCRIPT_DIR/vault-rag-embedding.sh" < "$PAYLOAD_TMP"; then
      log_err "embedding backend failed; falling back to keyword"
      "$SCRIPT_DIR/vault-rag-keyword.sh" < "$PAYLOAD_TMP"
    fi
    ;;
  *)
    log_err "unknown rag.backend=$BACKEND; using keyword"
    "$SCRIPT_DIR/vault-rag-keyword.sh" < "$PAYLOAD_TMP"
    ;;
esac

exit 0
