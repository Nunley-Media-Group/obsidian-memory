#!/usr/bin/env bash
# Shared preamble for obsidian-memory hook scripts.
#
# Usage (from the top of each hook):
#   . "$(dirname "$0")/_common.sh"
#   om_load_config rag       # or: distill — gates on .<feature>.enabled
#   PAYLOAD="$(om_read_payload)" || exit 0
#
# On success, exports: VAULT, CONFIG. On any failure (missing deps, missing
# config, disabled flag, empty payload) the loader exits 0 itself — a broken
# hook must never block the user.

set -u
trap 'exit 0' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

om_load_config() {
  local feature="$1"
  command -v jq >/dev/null 2>&1 || exit 0
  [ -r "$CONFIG" ] || exit 0

  local enabled_expr=".${feature}.enabled != false"
  IFS=$'\t' read -r VAULT ENABLED < <(
    jq -r "[.vaultPath // \"\", ($enabled_expr | tostring)] | @tsv" "$CONFIG" 2>/dev/null
  )
  [ -n "${VAULT:-}" ] || exit 0
  [ -d "$VAULT" ] || exit 0
  [ "${ENABLED:-}" = "true" ] || exit 0
  export VAULT
}

om_read_payload() {
  local payload
  payload="$(cat)"
  [ -n "$payload" ] || return 1
  printf '%s' "$payload"
}

# basename($1), lowercased, non-alphanumerics → '-', collapsed, trimmed.
om_slug() {
  basename "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g'
}
