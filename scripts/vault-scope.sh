#!/usr/bin/env bash
# vault-scope.sh — manage projects.mode / projects.excluded / projects.allowed
# in ~/.claude/obsidian-memory/config.json without hand-editing JSON.
#
# Thin-relayer: ships every mutation through jq into a same-directory temp
# file followed by `mv`. An interrupted write leaves the original config
# byte-identical. An EXIT trap clears the stray temp file on any path.
#
# Exit codes:
#   0 — success (status read, mutation, or already-in-state no-op)
#   1 — runtime error (missing config, missing jq, atomic-write failure)
#   2 — bad usage (unknown verb, unknown mode, too many arguments)

set -u

SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=scripts/_common.sh
. "$SCRIPT_DIR/_common.sh"
# Override the hook-style ERR trap from _common.sh: for a user-invoked CLI we
# want non-zero exits on unexpected failures, not a silent exit 0.
trap - ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"
TMP=""

log_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap
cleanup() {
  [ -n "$TMP" ] && rm -f "$TMP" 2>/dev/null
}
trap cleanup EXIT
trap 'log_err "failed at line $LINENO"; exit 1' ERR

usage_stderr() {
  cat >&2 <<'USAGE'
Usage:
  vault-scope.sh                                # status
  vault-scope.sh status                         # same as above
  vault-scope.sh current                        # print current cwd's slug
  vault-scope.sh mode (all|allowlist)           # set mode
  vault-scope.sh exclude (add|remove) [<slug>]  # add/remove; defaults to current slug
  vault-scope.sh exclude list                   # one slug per line
  vault-scope.sh allow   (add|remove) [<slug>]
  vault-scope.sh allow   list
USAGE
}

ensure_preconditions() {
  if ! command -v jq >/dev/null 2>&1; then
    log_err "jq missing — install jq (brew install jq)"
    exit 1
  fi
  if [ ! -f "$CONFIG" ]; then
    log_err "config not found — run /obsidian-memory:setup <vault> first"
    exit 1
  fi
  if [ ! -r "$CONFIG" ]; then
    log_err "config not readable at $CONFIG"
    exit 1
  fi
}

# Atomically rewrite $CONFIG with a given jq filter + args.
# Usage: atomic_write <filter> [jq-arg ...]
atomic_write() {
  local filter="$1"; shift
  TMP="$CONFIG.tmp.$$"
  if ! jq --indent 2 "$@" "$filter" "$CONFIG" > "$TMP" \
     || ! mv "$TMP" "$CONFIG"; then
    log_err "failed to write config"
    rm -f "$TMP" 2>/dev/null
    TMP=""
    return 1
  fi
  TMP=""
}

read_mode() {
  jq -r '.projects.mode // "all"' "$CONFIG" 2>/dev/null
}

# Echoes a comma-free list: one slug per line.
read_list() {
  local key="$1"
  jq -r --arg k "$key" '
    if (.projects[$k] | type) == "array"
    then .projects[$k][]
    else empty
    end
  ' "$CONFIG" 2>/dev/null
}

list_contains() {
  local key="$1" slug="$2"
  local line
  while IFS= read -r line; do
    [ "$line" = "$slug" ] && return 0
  done < <(read_list "$key")
  return 1
}

current_slug() {
  # vault-scope.sh is a user-invoked CLI, so the "current project" is the
  # operator's shell cwd ($PWD). The hook scripts pull cwd from the JSON
  # payload instead — never reuse this helper from a hook context.
  om_slug "$PWD"
}

# Compare current project's policy bucket before/after a mutation. Prints the
# mid-session-caveat line to stdout when the bucket has changed.
maybe_emit_caveat() {
  local before="$1" after="$2"
  if [ "$before" != "$after" ]; then
    printf 'Note: overrides apply to sessions that start AFTER this change; the current session is unaffected.\n'
  fi
}

format_list_for_stdout() {
  local key="$1"
  local out
  out="$(read_list "$key" | paste -sd , - 2>/dev/null)"
  [ -n "$out" ] || out="(none)"
  printf '%s' "$out"
}

cmd_status() {
  local mode excluded_s allowed_s
  mode="$(read_mode)"
  excluded_s="$(format_list_for_stdout excluded)"
  allowed_s="$(format_list_for_stdout allowed)"
  printf 'mode: %s\n' "$mode"
  printf 'current: %s\n' "$(current_slug)"
  printf 'excluded: %s\n' "$excluded_s"
  printf 'allowed: %s\n' "$allowed_s"
}

cmd_current() {
  printf '%s\n' "$(current_slug)"
}

cmd_mode() {
  local new="$1"
  case "$new" in
    all|allowlist) ;;
    *)
      log_err "unknown mode '$new' — allowed: all, allowlist"
      exit 2
      ;;
  esac

  local current
  current="$(read_mode)"
  if [ "$current" = "$new" ]; then
    printf 'projects.mode was already %s\n' "$new"
    return 0
  fi

  local before after
  before="$(om_policy_state "$PWD")"

  # shellcheck disable=SC2016  # $m is a jq variable, not a shell expansion
  atomic_write '.projects = ((.projects // {}) | .mode = $m)' --arg m "$new" \
    || exit 1

  after="$(om_policy_state "$PWD")"
  printf 'projects.mode: %s -> %s\n' "$current" "$new"

  if [ "$new" = "allowlist" ]; then
    local allowed_count
    allowed_count="$(jq -r '(.projects.allowed // []) | length' "$CONFIG" 2>/dev/null)"
    if [ "${allowed_count:-0}" = "0" ]; then
      printf 'WARNING: allowlist mode with no allowed projects — all projects will no-op\n' >&2
    fi
  fi

  maybe_emit_caveat "$before" "$after"
}

_normalize_slug_arg() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf '%s' "$(current_slug)"
    return 0
  fi
  printf '%s' "$(om_slug "$raw")"
}

# Map a user-facing list verb (exclude/allow) to its storage key
# (excluded/allowed). Centralises the verb↔key translation so error messages
# quote the user's typed verb while jq reads/writes the real key.
_verb_to_key() {
  case "$1" in
    exclude) printf 'excluded' ;;
    allow)   printf 'allowed'  ;;
    *)       log_err "unknown list verb '$1'"; return 1 ;;
  esac
}

cmd_list_add() {
  local verb="$1" slug_raw="${2:-}"
  local key
  key="$(_verb_to_key "$verb")"
  local slug
  slug="$(_normalize_slug_arg "$slug_raw")"
  if [ -z "$slug" ]; then
    log_err "could not derive a slug from '$slug_raw' (or current PWD)"
    exit 1
  fi

  if list_contains "$key" "$slug"; then
    printf 'projects.%s already contains "%s"\n' "$key" "$slug"
    return 0
  fi

  local before after
  before="$(om_policy_state "$PWD")"

  # shellcheck disable=SC2016  # $k / $s are jq variables, not shell expansions
  atomic_write '.projects = ((.projects // {}) | .[$k] = (((.[$k] // []) + [$s]) | unique))' \
    --arg k "$key" --arg s "$slug" \
    || exit 1

  after="$(om_policy_state "$PWD")"
  printf 'projects.%s: added "%s"\n' "$key" "$slug"
  maybe_emit_caveat "$before" "$after"
}

cmd_list_remove() {
  local verb="$1" slug_raw="${2:-}"
  local key
  key="$(_verb_to_key "$verb")"
  local slug
  slug="$(_normalize_slug_arg "$slug_raw")"
  if [ -z "$slug" ]; then
    log_err "could not derive a slug from '$slug_raw' (or current PWD)"
    exit 1
  fi

  if ! list_contains "$key" "$slug"; then
    printf 'projects.%s did not contain "%s"\n' "$key" "$slug"
    return 0
  fi

  local before after
  before="$(om_policy_state "$PWD")"

  # shellcheck disable=SC2016  # $k / $s are jq variables, not shell expansions
  atomic_write '.projects = ((.projects // {}) | .[$k] = ((.[$k] // []) | map(select(. != $s))))' \
    --arg k "$key" --arg s "$slug" \
    || exit 1

  after="$(om_policy_state "$PWD")"
  printf 'projects.%s: removed "%s"\n' "$key" "$slug"
  maybe_emit_caveat "$before" "$after"
}

cmd_list_list() {
  local verb="$1"
  read_list "$(_verb_to_key "$verb")"
}

dispatch_list_verb() {
  local verb="$1" sub="${2:-}"; shift || true; shift || true
  case "$sub" in
    "")
      log_err "missing sub-verb for '$verb' — expected one of: add, remove, list"
      exit 2
      ;;
    add)
      if [ "$#" -gt 1 ]; then
        log_err "too many arguments for '$verb add'"
        exit 2
      fi
      cmd_list_add "$verb" "${1:-}"
      ;;
    remove)
      if [ "$#" -gt 1 ]; then
        log_err "too many arguments for '$verb remove'"
        exit 2
      fi
      cmd_list_remove "$verb" "${1:-}"
      ;;
    list)
      if [ "$#" -gt 0 ]; then
        log_err "too many arguments for '$verb list'"
        exit 2
      fi
      cmd_list_list "$verb"
      ;;
    *)
      log_err "unknown sub-verb '$sub' for '$verb' — allowed: add, remove, list"
      exit 2
      ;;
  esac
}

main() {
  if [ "$#" -eq 0 ]; then
    ensure_preconditions
    cmd_status
    exit 0
  fi

  local verb="$1"; shift
  case "$verb" in
    -h|--help)
      usage_stderr
      exit 0
      ;;
    status)
      if [ "$#" -gt 0 ]; then
        log_err "too many arguments for 'status'"
        exit 2
      fi
      ensure_preconditions
      cmd_status
      ;;
    current)
      if [ "$#" -gt 0 ]; then
        log_err "too many arguments for 'current'"
        exit 2
      fi
      # current does not strictly need the config — but keep the contract
      # consistent by requiring jq and config existence like every other verb.
      ensure_preconditions
      cmd_current
      ;;
    mode)
      if [ "$#" -ne 1 ]; then
        log_err "'mode' requires exactly one argument (all|allowlist)"
        exit 2
      fi
      ensure_preconditions
      cmd_mode "$1"
      ;;
    exclude|allow)
      ensure_preconditions
      dispatch_list_verb "$verb" "$@"
      ;;
    *)
      log_err "unknown verb '$verb' — allowed: status, current, mode, exclude, allow"
      exit 2
      ;;
  esac
  exit 0
}

main "$@"
