#!/usr/bin/env bash
# vault-doctor.sh — read-only install-state reporter for obsidian-memory.
#
# Runs every probe without short-circuiting so the user sees the full picture
# from a single invocation. Never mutates the filesystem. Exits 0 if every
# probe is OK/INFO; exits 1 if any probe is FAIL; exits 2 on bad usage.

set -u

# shellcheck disable=SC2329  # invoked indirectly by the ERR trap
log_err() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }

# Source the shared helpers (pulls in om_describe_distill_template, om_slug,
# etc.). _common.sh installs its own `trap 'exit 0' ERR` for hook-safety —
# doctor re-installs its own ERR trap immediately after so an unexpected
# failure still exits 1 (doctor's contract) instead of 0 (hook contract).
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
trap 'log_err "failed at line $LINENO"; exit 1' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

# --- ANSI color (TTY only) ---------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_BOLD=""
fi

# --- Result accumulators (parallel arrays keyed by index) -------------------

PROBE_KEYS=()
PROBE_STATUS=()   # ok | fail | info
PROBE_DETAIL=()   # human-readable detail (path, reason, note)
PROBE_HINT=()     # remediation hint (fail only; empty otherwise)

_record() {
  # $1 = key, $2 = status, $3 = detail, $4 = hint (optional)
  PROBE_KEYS+=("$1")
  PROBE_STATUS+=("$2")
  PROBE_DETAIL+=("$3")
  PROBE_HINT+=("${4:-}")
}

# --- Probe helpers -----------------------------------------------------------

_jq_available=1
_claude_available=1
_config_readable=0
_vault_path=""

probe_config() {
  if [ -r "$CONFIG" ]; then
    _record "config" "ok" "$CONFIG"
    _config_readable=1
  else
    _record "config" "fail" \
      "config file $CONFIG is missing" \
      "run /obsidian-memory:setup <vault>"
  fi
}

probe_jq() {
  if command -v jq >/dev/null 2>&1; then
    _record "jq" "ok" "$(command -v jq)"
  else
    _record "jq" "fail" "jq not on PATH" "brew install jq"
    _jq_available=0
  fi
}

probe_vault_path() {
  if [ "$_config_readable" -ne 1 ]; then
    _record "vault_path" "fail" \
      "cannot check vaultPath — config missing" \
      "run /obsidian-memory:setup <vault>"
    return
  fi
  if [ "$_jq_available" -ne 1 ]; then
    _record "vault_path" "fail" \
      "cannot check vaultPath — jq missing" \
      "brew install jq"
    return
  fi

  local raw
  raw="$(jq -r '.vaultPath // ""' "$CONFIG" 2>/dev/null || printf '')"
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    _record "vault_path" "fail" \
      "vaultPath missing from config" \
      "run /obsidian-memory:setup <vault>"
    return
  fi

  _vault_path="$raw"

  if [ ! -d "$raw" ]; then
    _record "vault_path" "fail" \
      "vault path $raw does not exist" \
      "run /obsidian-memory:setup <vault>"
    return
  fi

  _record "vault_path" "ok" "$raw"
}

probe_claude() {
  if command -v claude >/dev/null 2>&1; then
    _record "claude" "ok" "$(command -v claude)"
  else
    _record "claude" "fail" \
      "claude not on PATH" \
      "install the Claude Code CLI; see https://docs.claude.com/claude-code"
    _claude_available=0
  fi
}

probe_sessions_dir() {
  if [ -z "$_vault_path" ]; then
    _record "sessions_dir" "fail" \
      "cannot check sessions directory — vault path unresolved" \
      "run /obsidian-memory:setup <vault>"
    return
  fi
  local sessions="$_vault_path/claude-memory/sessions"
  if [ -d "$sessions" ]; then
    _record "sessions_dir" "ok" "$sessions"
  else
    _record "sessions_dir" "fail" \
      "sessions directory $sessions does not exist" \
      "run /obsidian-memory:setup <vault>"
  fi
}

probe_projects_symlink() {
  if [ -z "$_vault_path" ]; then
    _record "projects_symlink" "fail" \
      "cannot check projects symlink — vault path unresolved" \
      "run /obsidian-memory:setup <vault>"
    return
  fi
  local link="$_vault_path/claude-memory/projects"
  local expected="$HOME/.claude/projects"

  if [ ! -L "$link" ]; then
    _record "projects_symlink" "fail" \
      "projects symlink $link is missing" \
      "run /obsidian-memory:setup <vault>"
    return
  fi

  local target
  target="$(readlink "$link" 2>/dev/null || printf '')"
  if [ "$target" != "$expected" ]; then
    _record "projects_symlink" "fail" \
      "projects symlink $link points at $target (expected $expected)" \
      "run /obsidian-memory:setup <vault>"
    return
  fi

  if [ ! -e "$link" ]; then
    _record "projects_symlink" "fail" \
      "projects symlink $link is broken (target $target does not exist)" \
      "run /obsidian-memory:setup <vault>"
    return
  fi

  _record "projects_symlink" "ok" "$link -> $target"
}

_flag_enabled() {
  # Echo "true" or "false". Unset flags read as true (matches _common.sh).
  # Using `!= false` rather than `// true` because jq's `//` alternative
  # operator treats `false` as "absent" and would wrongly fall through.
  local key="$1"
  local val
  val="$(jq -r "(.${key}.enabled != false) | tostring" "$CONFIG" 2>/dev/null || printf 'true')"
  printf '%s' "$val"
}

probe_flag_enabled() {
  local feature="$1"
  if [ "$_config_readable" -ne 1 ] || [ "$_jq_available" -ne 1 ]; then
    _record "${feature}_enabled" "fail" \
      "cannot check ${feature}.enabled — config or jq missing" \
      "run /obsidian-memory:setup <vault>"
    return
  fi
  local val
  val="$(_flag_enabled "$feature")"
  if [ "$val" = "true" ]; then
    _record "${feature}_enabled" "ok" "true"
  else
    _record "${feature}_enabled" "fail" \
      "${feature}.enabled is false in config" \
      "run /obsidian-memory:toggle ${feature} on"
  fi
}

probe_scope_mode() {
  if [ "$_config_readable" -ne 1 ] || [ "$_jq_available" -ne 1 ]; then
    _record "scope_mode" "info" "cannot read — config or jq missing"
    return
  fi
  local mode excluded_n allowed_n
  IFS=$'\t' read -r mode excluded_n allowed_n < <(
    jq -r '[
      (.projects.mode // "all"),
      ((.projects.excluded // []) | length),
      ((.projects.allowed  // []) | length)
    ] | @tsv' "$CONFIG" 2>/dev/null
  )
  mode="${mode:-all}"
  if [ "$mode" = "all" ] && [ "${excluded_n:-0}" = "0" ]; then
    _record "scope_mode" "info" "all (unscoped)"
  else
    _record "scope_mode" "info" \
      "$mode (excluded: ${excluded_n:-0}, allowed: ${allowed_n:-0})"
  fi
}

probe_distill_template() {
  # Reports the active distillation template as an info line. Runs regardless
  # of distill.enabled — a mis-configured template_path is worth surfacing
  # even while the feature is toggled off.
  if [ "$_config_readable" -ne 1 ] || [ "$_jq_available" -ne 1 ]; then
    _record "distill_template" "info" "cannot read — config or jq missing"
    return
  fi
  local slug descriptor
  slug="$(om_slug "${PWD:-$HOME}")"
  [ -n "$slug" ] || slug="unknown"
  descriptor="$(om_describe_distill_template "$slug")"
  _record "distill_template" "info" "$descriptor"
}

probe_ripgrep() {
  if command -v rg >/dev/null 2>&1; then
    _record "ripgrep" "info" "$(command -v rg)"
  else
    _record "ripgrep" "info" \
      "ripgrep not on PATH — vault-rag.sh will use POSIX fallback"
  fi
}

probe_mcp() {
  if [ "$_claude_available" -ne 1 ]; then
    _record "mcp" "info" "claude not on PATH — mcp status unknown"
    return
  fi

  # Keep `|| rc=$?` so the ERR trap doesn't fire when claude itself exits non-zero.
  local out rc=0
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 3 claude mcp list 2>/dev/null)" || rc=$?
  else
    out="$(claude mcp list 2>/dev/null)" || rc=$?
  fi

  if [ "$rc" -eq 124 ]; then
    _record "mcp" "info" "mcp status unknown (claude mcp list timed out)"
    return
  fi

  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    _record "mcp" "info" "mcp status unknown"
    return
  fi

  if printf '%s' "$out" | grep -qi 'obsidian'; then
    _record "mcp" "info" "obsidian MCP server registered"
  else
    _record "mcp" "info" "obsidian MCP server not registered"
  fi
}

# --- Output formatters -------------------------------------------------------

_status_label() {
  case "$1" in
    ok)   printf '%sOK  %s' "$C_GREEN" "$C_RESET" ;;
    fail) printf '%sFAIL%s' "$C_RED" "$C_RESET" ;;
    info) printf '%sINFO%s' "$C_YELLOW" "$C_RESET" ;;
    *)    printf '%s' "$1" ;;
  esac
}

emit_human() {
  printf '%sobsidian-memory doctor%s\n' "$C_BOLD" "$C_RESET"
  printf '%s\n' "──────────────────────"

  local fails=0 i status detail hint label line
  local n="${#PROBE_KEYS[@]}"
  for (( i = 0; i < n; i++ )); do
    status="${PROBE_STATUS[$i]}"
    detail="${PROBE_DETAIL[$i]}"
    hint="${PROBE_HINT[$i]}"
    label="$(_status_label "$status")"
    case "$status" in
      ok)
        printf '%s  %-18s %s\n' "$label" "${PROBE_KEYS[$i]}" "$detail"
        ;;
      fail)
        line="${PROBE_KEYS[$i]}: $detail"
        if [ -n "$hint" ]; then
          line="$line — $hint"
        fi
        printf '%s  %s\n' "$label" "$line"
        fails=$((fails + 1))
        ;;
      info)
        printf '%s  %-18s %s\n' "$label" "${PROBE_KEYS[$i]}" "$detail"
        ;;
    esac
  done

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    printf '%sAll checks passed.%s\n' "$C_BOLD" "$C_RESET"
  else
    printf '%s%d check(s) failed.%s\n' "$C_BOLD" "$fails" "$C_RESET"
  fi
}

emit_json() {
  local ok=true i n="${#PROBE_KEYS[@]}"
  for (( i = 0; i < n; i++ )); do
    if [ "${PROBE_STATUS[$i]}" = "fail" ]; then ok=false; break; fi
  done

  if [ "$_jq_available" -ne 1 ]; then
    # Fallback: hand-assembled JSON. Strings have no special chars in practice
    # (paths + ASCII hints), but we still quote conservatively.
    local first=1
    printf '{"ok":%s,"checks":{' "$ok"
    for (( i = 0; i < n; i++ )); do
      if [ "$first" -eq 0 ]; then printf ','; fi
      first=0
      printf '"%s":{"status":"%s"' "${PROBE_KEYS[$i]}" "${PROBE_STATUS[$i]}"
      case "${PROBE_STATUS[$i]}" in
        fail)
          printf ',"reason":"%s","hint":"%s"' \
            "$(_json_escape "${PROBE_DETAIL[$i]}")" \
            "$(_json_escape "${PROBE_HINT[$i]}")"
          ;;
        info)
          printf ',"note":"%s"' "$(_json_escape "${PROBE_DETAIL[$i]}")"
          ;;
      esac
      printf '}'
    done
    printf '}}\n'
    return
  fi

  local args=()
  for (( i = 0; i < n; i++ )); do
    args+=( --arg "k$i" "${PROBE_KEYS[$i]}" )
    args+=( --arg "s$i" "${PROBE_STATUS[$i]}" )
    args+=( --arg "d$i" "${PROBE_DETAIL[$i]}" )
    args+=( --arg "h$i" "${PROBE_HINT[$i]}" )
  done

  # shellcheck disable=SC2016  # $ok is a jq variable, not a shell expansion
  local filter='{ok: $ok, checks: {}}'
  for (( i = 0; i < n; i++ )); do
    filter="$filter
      | .checks[\$k${i}] = (
          if \$s${i} == \"fail\" then
            {status: \$s${i}, reason: \$d${i}, hint: \$h${i}}
          elif \$s${i} == \"info\" then
            {status: \$s${i}, note: \$d${i}}
          else
            {status: \$s${i}}
          end
        )"
  done

  jq -n --argjson ok "$ok" "${args[@]}" "$filter"
}

_json_escape() {
  # Minimal JSON string escaping for the fallback encoder. Not bulletproof,
  # but enough for ASCII paths and hints we actually emit.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/$/\\n/g' | tr -d '\n' | sed 's/\\n$//'
}

# --- CLI ---------------------------------------------------------------------

usage() {
  cat >&2 <<'USAGE'
Usage: vault-doctor.sh [--json]

  --json   Emit a machine-readable JSON report.

Prints a read-only health check of the obsidian-memory install. Exits 0 if
every probe is OK or INFO; exits 1 if any probe is FAIL.
USAGE
}

main() {
  local json_mode=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json_mode=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
    shift
  done

  if [ "$json_mode" -eq 1 ]; then
    C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""
  fi

  probe_config
  probe_jq
  probe_vault_path
  probe_claude
  probe_sessions_dir
  probe_projects_symlink
  probe_flag_enabled rag
  probe_flag_enabled distill
  probe_scope_mode
  probe_distill_template
  probe_ripgrep
  probe_mcp

  if [ "$json_mode" -eq 1 ]; then
    emit_json
  else
    emit_human
  fi

  local i n="${#PROBE_KEYS[@]}"
  for (( i = 0; i < n; i++ )); do
    if [ "${PROBE_STATUS[$i]}" = "fail" ]; then
      exit 1
    fi
  done
  exit 0
}

main "$@"
