#!/usr/bin/env bash
# vault-toggle.sh — flip rag.enabled / distill.enabled in config.json.
#
# User-invoked (unlike the silent hook scripts), so errors surface instead of
# silently no-op'ing: missing config, unknown feature, unknown state alias, or
# a failed write all exit non-zero with a descriptive ERROR: line on stderr.
#
# Mutating writes go through jq into a same-directory temp file followed by
# mv — a SIGKILL between steps leaves the original config intact, and an
# EXIT trap cleans any stray temp file.
#
# Exit codes:
#   0 — success (status, successful mutation, "was already" no-op)
#   1 — runtime error (missing config, missing jq, atomic-write failure)
#   2 — bad usage (unknown feature, unknown state alias, too many args)

set -u

CONFIG="${HOME}/.claude/obsidian-memory/config.json"
TMP=""

# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap
cleanup() {
  [ -n "$TMP" ] && rm -f "$TMP" 2>/dev/null
}
trap cleanup EXIT

log_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

usage_stderr() {
  cat >&2 <<'USAGE'
Usage:
  vault-toggle.sh                        # print status for both flags
  vault-toggle.sh status                 # same as above
  vault-toggle.sh <feature>              # flip current value
  vault-toggle.sh <feature> <state>      # set explicit value

<feature> ::= rag | distill
<state>   ::= on | off | true | false | 1 | 0 | yes | no   (case-insensitive)
USAGE
}

# Map a state alias to "true" / "false". Anything else → empty output, exit 1.
normalize_state() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    on|true|1|yes) printf 'true' ;;
    off|false|0|no) printf 'false' ;;
    *) return 1 ;;
  esac
}

# Read .<feature>.enabled from the config, normalising unset/null to "true".
# Used for status output and for computing the flipped value in cmd_flip.
read_flag() {
  local feature="$1"
  jq -r "(.${feature}.enabled != false) | tostring" "$CONFIG" 2>/dev/null
}

# Raw read: "true" / "false" if explicitly set, empty string if unset/null.
# Used by cmd_set to decide whether the mutation is a no-op. An unset flag is
# NOT "already in state" — the user expects an explicit write so the stanza
# lands in the config (design.md → Risks → "unset ambiguity").
read_flag_raw() {
  local feature="$1"
  jq -r ".${feature}.enabled? // empty | tostring" "$CONFIG" 2>/dev/null
}

# Atomically rewrite the config with .<feature>.enabled = <bool>.
write_flag() {
  local feature="$1" value="$2"
  TMP="$CONFIG.tmp.$$"
  if ! jq --indent 2 --argjson v "$value" ".${feature}.enabled = \$v" "$CONFIG" > "$TMP"; then
    log_err "failed to write config"
    return 1
  fi
  if ! mv "$TMP" "$CONFIG"; then
    log_err "failed to write config"
    return 1
  fi
  TMP=""
  return 0
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

cmd_status() {
  ensure_preconditions
  local rag distill
  IFS=$'\t' read -r rag distill < <(
    jq -r '[(.rag.enabled != false), (.distill.enabled != false)] | @tsv' "$CONFIG" 2>/dev/null
  )
  printf 'rag.enabled: %s\n' "$rag"
  printf 'distill.enabled: %s\n' "$distill"
}

cmd_set() {
  local feature="$1" new_value="$2"
  ensure_preconditions

  local raw
  raw="$(read_flag_raw "$feature")"

  if [ "$raw" = "$new_value" ]; then
    printf '%s.enabled was already %s\n' "$feature" "$raw"
    return 0
  fi

  write_flag "$feature" "$new_value" || exit 1

  # Report the effective prior value (unset → "true") so the output always
  # shows a concrete boolean rather than an empty prev field.
  local prev="$raw"
  [ -n "$prev" ] || prev="true"
  printf '%s.enabled: %s -> %s\n' "$feature" "$prev" "$new_value"
}

cmd_flip() {
  local feature="$1"
  ensure_preconditions

  local current new
  current="$(read_flag "$feature")"
  if [ "$current" = "true" ]; then new="false"; else new="true"; fi

  write_flag "$feature" "$new" || exit 1
  printf '%s.enabled: %s -> %s\n' "$feature" "$current" "$new"
}

main() {
  if [ "$#" -gt 2 ]; then
    usage_stderr
    exit 2
  fi

  if [ "$#" -eq 0 ]; then
    cmd_status
    exit 0
  fi

  local first="$1"
  if [ "$first" = "status" ] && [ "$#" -eq 1 ]; then
    cmd_status
    exit 0
  fi

  case "$first" in
    rag|distill) ;;
    -h|--help) usage_stderr; exit 0 ;;
    *)
      log_err "unknown feature '$first' — allowed: rag, distill"
      exit 2
      ;;
  esac

  if [ "$#" -eq 1 ]; then
    cmd_flip "$first"
    exit 0
  fi

  local state_raw="$2" state_norm
  if ! state_norm="$(normalize_state "$state_raw")"; then
    log_err "unknown state '$state_raw' — allowed: on, off, true, false, 1, 0, yes, no"
    exit 2
  fi

  cmd_set "$first" "$state_norm"
  exit 0
}

main "$@"
