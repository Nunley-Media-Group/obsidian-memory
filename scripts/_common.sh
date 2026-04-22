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

# basename($1), lowercased, non-alphanumerics → '-', collapsed, trimmed,
# length-capped at 60 characters. Truncation may expose a trailing hyphen
# (when char 60 is '-'); a final sed strip handles that case.
om_slug() {
  basename "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-|-$//g' \
    | cut -c1-60 \
    | sed -E 's/-$//'
}

# Usage:  _om_slug_in_csv "$slug" "$csv"   (returns 0 if present, 1 if not)
_om_slug_in_csv() {
  local needle="$1" csv="$2"
  [ -n "$csv" ] || return 1
  local stripped
  stripped="$(printf '%s' "$csv" | tr -d '"')"
  local IFS_SAVED="$IFS"
  local found=1
  IFS=','
  # shellcheck disable=SC2086
  set -- $stripped
  IFS="$IFS_SAVED"
  local item
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      found=0
      break
    fi
  done
  return "$found"
}

# _om_read_projects_policy — prints three newline-separated fields on stdout:
#   1. mode           (coerced to "all" when unknown)
#   2. excluded_csv   (jq @csv; empty string when array is empty)
#   3. allowed_csv    (same)
# Malformed shapes produce a single stderr warning per field. Shared by
# om_project_allowed and om_policy_state. Newline-delimited (not tab) because
# bash `read` with whitespace IFS collapses consecutive delimiters, which
# would lose empty fields.
_om_read_projects_policy() {
  if [ ! -r "$CONFIG" ]; then
    printf 'all\n\n\n'
    return 0
  fi
  local mode excluded allowed
  { IFS= read -r mode; IFS= read -r excluded; IFS= read -r allowed; } < <(
    jq -r '
      (.projects.mode // "all"),
      (
        if .projects.excluded == null then ""
        elif (.projects.excluded | type) == "array" then (.projects.excluded | @csv)
        else "__INVALID__" end
      ),
      (
        if .projects.allowed == null then ""
        elif (.projects.allowed | type) == "array" then (.projects.allowed | @csv)
        else "__INVALID__" end
      )
    ' "$CONFIG" 2>/dev/null
  )
  mode="${mode:-all}"

  case "$mode" in
    all|allowlist) ;;
    *)
      printf '[%s] projects.mode=%q — treating as "all"\n' "$(basename "${0:-om}")" "$mode" >&2
      mode="all"
      ;;
  esac

  if [ "$excluded" = "__INVALID__" ]; then
    printf '[%s] projects.excluded is not an array — treating as []\n' "$(basename "${0:-om}")" >&2
    excluded=""
  fi
  if [ "$allowed" = "__INVALID__" ]; then
    printf '[%s] projects.allowed is not an array — treating as []\n' "$(basename "${0:-om}")" >&2
    allowed=""
  fi

  printf '%s\n%s\n%s\n' "$mode" "$excluded" "$allowed"
}

# om_policy_state "$CWD" — echoes the current policy outcome for $CWD as
# exactly one of: all | excluded | allowlist-hit | allowlist-miss.
# Used by vault-session-start.sh to take the per-session snapshot.
om_policy_state() {
  local cwd="${1:-$PWD}"
  local slug
  slug="$(om_slug "$cwd")"
  if [ -z "$slug" ]; then
    printf 'all\n'
    return 0
  fi

  local mode excluded allowed
  { IFS= read -r mode; IFS= read -r excluded; IFS= read -r allowed; } < <(_om_read_projects_policy)

  if [ "$mode" = "all" ]; then
    if _om_slug_in_csv "$slug" "$excluded"; then
      printf 'excluded\n'
    else
      printf 'all\n'
    fi
    return 0
  fi

  if _om_slug_in_csv "$slug" "$allowed"; then
    printf 'allowlist-hit\n'
  else
    printf 'allowlist-miss\n'
  fi
}

# om_project_allowed "$CWD" — return 0 if the project is permitted, 1 if not.
# Missing / malformed shape → permissive default (mode=all, empty lists).
# Never exits on its own.
om_project_allowed() {
  local state
  state="$(om_policy_state "${1:-$PWD}")"
  case "$state" in
    excluded|allowlist-miss) return 1 ;;
    *) return 0 ;;
  esac
}
