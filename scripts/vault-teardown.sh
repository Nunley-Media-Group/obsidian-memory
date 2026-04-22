#!/usr/bin/env bash
# vault-teardown.sh — inverse of /obsidian-memory:setup.
#
# Removes the obsidian-memory install footprint:
#   - ~/.claude/obsidian-memory/config.json
#   - <vault>/claude-memory/projects  (symlink only, never a real directory)
# Optionally:
#   --purge           additionally deletes <vault>/claude-memory/sessions/
#                     and <vault>/claude-memory/Index.md after a typed "yes"
#                     confirmation (exact literal, case-sensitive)
#   --unregister-mcp  best-effort `claude mcp remove obsidian -s user`
#   --dry-run         prints the plan; touches nothing; never prompts
#
# Exit codes:
#   0  success (including idempotent no-op and cancelled purge)
#   1  path-safety refusal — layout does not match setup's footprint
#   2  bad usage (unknown flag)

set -u

# shellcheck disable=SC2329  # invoked indirectly by the ERR trap
log_err() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
trap 'log_err "failed at line $LINENO"; exit 1' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"
EXPECTED_PROJECTS_TARGET="${HOME}/.claude/projects"

# --- ANSI color (TTY only) --------------------------------------------------

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

# --- CLI --------------------------------------------------------------------

PURGE=0
UNREGISTER_MCP=0
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
Usage: vault-teardown.sh [--purge] [--unregister-mcp] [--dry-run]

  --purge           Additionally delete distilled sessions and Index.md.
                    Requires typing the literal string 'yes' at the prompt.
  --unregister-mcp  Best-effort unregister the Obsidian MCP server.
  --dry-run         Print the plan and exit 0 without touching anything.

Reverses the footprint written by /obsidian-memory:setup. Exits 0 on success
(including the idempotent no-op and cancelled purge); exits 1 on a path-safety
refusal; exits 2 on bad usage.
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge)          PURGE=1 ;;
      --unregister-mcp) UNREGISTER_MCP=1 ;;
      --dry-run)        DRY_RUN=1 ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage; exit 2 ;;
    esac
    shift
  done
}

# --- Output helpers ---------------------------------------------------------

print_header() {
  printf '%sobsidian-memory teardown%s\n' "$C_BOLD" "$C_RESET"
  printf '%s\n' "────────────────────────"
}

print_vault_line() {
  printf 'vault: %s\n\n' "$1"
}

# --- Refusal (Stage 2 failure) ---------------------------------------------

refuse() {
  # $1 = vault path (may be "(unknown)"), $2 = mismatch description
  local vault="$1" reason="$2"
  print_header
  print_vault_line "$vault"
  printf '%sREFUSED%s\n' "${C_BOLD}${C_RED}" "$C_RESET"
  printf '  %s\n' "$reason"
  printf '  This does not look like an obsidian-memory install — refusing to delete anything.\n'
  printf '  Run /obsidian-memory:doctor to diagnose the config, then reconcile manually.\n'
  exit 1
}

# --- Stage 1: discover ------------------------------------------------------

VAULT=""

discover() {
  if [ ! -f "$CONFIG" ]; then
    print_header
    printf 'No obsidian-memory config found at %s — nothing to do.\n' "$CONFIG"
    exit 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    refuse "(unknown)" \
      "jq is not on PATH; cannot read vaultPath from $CONFIG — install jq and retry."
  fi

  local raw
  raw="$(jq -r '.vaultPath // ""' "$CONFIG" 2>/dev/null || printf '')"
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    refuse "(unknown)" \
      "vaultPath is missing or empty in $CONFIG."
  fi
  VAULT="$raw"
}

# --- Stage 2: validate (path-safety gate) ----------------------------------

validate() {
  if [ ! -d "$VAULT" ]; then
    refuse "$VAULT" "$VAULT does not exist or is not a directory."
  fi

  local cm="$VAULT/claude-memory"
  if [ ! -d "$cm" ]; then
    refuse "$VAULT" "$VAULT does not contain a claude-memory/ directory."
  fi

  local projects="$cm/projects"
  # Projects entry must be either absent OR a symlink that resolves to the
  # expected target via plain readlink (no -f — BSD readlink lacks it).
  if [ -e "$projects" ] || [ -L "$projects" ]; then
    if [ ! -L "$projects" ]; then
      refuse "$VAULT" \
        "$projects exists but is not a symlink created by setup."
    fi
    local target
    target="$(readlink "$projects" 2>/dev/null || printf '')"
    if [ "$target" != "$EXPECTED_PROJECTS_TARGET" ]; then
      refuse "$VAULT" \
        "$projects points at $target (expected $EXPECTED_PROJECTS_TARGET)."
    fi
  fi
}

# --- Stage 3: plan ----------------------------------------------------------

# Parallel arrays keyed by index; each entry is "kind:path-or-note".
PLAN_REMOVE=()
PLAN_PRESERVE=()
SESSIONS_COUNT=0

count_sessions() {
  local sessions="$VAULT/claude-memory/sessions"
  if [ -d "$sessions" ]; then
    SESSIONS_COUNT="$(
      find "$sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]'
    )"
    [ -n "$SESSIONS_COUNT" ] || SESSIONS_COUNT=0
  else
    SESSIONS_COUNT=0
  fi
}

compose_plan() {
  count_sessions
  local cm="$VAULT/claude-memory"
  local projects="$cm/projects"
  local sessions="$cm/sessions"
  local index="$cm/Index.md"

  PLAN_REMOVE+=("config:$CONFIG")
  if [ -L "$projects" ]; then
    PLAN_REMOVE+=("symlink:$projects")
  fi

  if [ "$PURGE" -eq 1 ]; then
    if [ -d "$sessions" ]; then
      PLAN_REMOVE+=("sessions:$sessions")
    fi
    if [ -f "$index" ]; then
      PLAN_REMOVE+=("index:$index")
    fi
  else
    if [ -d "$sessions" ]; then
      PLAN_PRESERVE+=("sessions:$sessions")
    fi
    if [ -f "$index" ]; then
      PLAN_PRESERVE+=("index:$index")
    fi
  fi

  if [ "$UNREGISTER_MCP" -eq 1 ]; then
    PLAN_REMOVE+=("mcp:obsidian MCP server registration")
  fi
}

# Move sessions + Index.md entries from PLAN_REMOVE back into PLAN_PRESERVE
# after a cancelled purge.
demote_sessions_to_preserve() {
  local sessions="$VAULT/claude-memory/sessions"
  local index="$VAULT/claude-memory/Index.md"
  local new=() entry
  for entry in "${PLAN_REMOVE[@]}"; do
    case "$entry" in
      sessions:*|index:*) : ;;
      *) new+=("$entry") ;;
    esac
  done
  PLAN_REMOVE=("${new[@]}")
  if [ -d "$sessions" ]; then
    PLAN_PRESERVE+=("sessions:$sessions")
  fi
  if [ -f "$index" ]; then
    PLAN_PRESERVE+=("index:$index")
  fi
}

# --- Plan rendering ---------------------------------------------------------

_format_line() {
  # $1 = label (REMOVE / PRESERVE / WOULD REMOVE / WOULD PRESERVE / REMOVED / PRESERVED)
  # $2 = color, $3 = entry ("kind:value")
  local label="$1" color="$2" entry="$3"
  local kind="${entry%%:*}" value="${entry#*:}"
  local annotation=""
  case "$kind" in
    symlink)  annotation=" (symlink)" ;;
    sessions) annotation="  (${SESSIONS_COUNT} notes)" ;;
    mcp)      : ;;
    *)        : ;;
  esac
  printf '  %s%-10s%s %s%s\n' "$color" "$label" "$C_RESET" "$value" "$annotation"
}

print_plan_section() {
  local mode="$1"
  local remove_label preserve_label remove_color preserve_color
  case "$mode" in
    dry_run)
      remove_label="WOULD REMOVE"
      preserve_label="WOULD PRESERVE"
      remove_color="$C_YELLOW"
      preserve_color="$C_YELLOW"
      ;;
    *)
      remove_label="REMOVE"
      preserve_label="PRESERVE"
      remove_color="$C_RED"
      preserve_color="$C_GREEN"
      ;;
  esac

  printf 'PLAN\n'
  local entry
  for entry in "${PLAN_REMOVE[@]}"; do
    _format_line "$remove_label" "$remove_color" "$entry"
  done
  for entry in "${PLAN_PRESERVE[@]}"; do
    _format_line "$preserve_label" "$preserve_color" "$entry"
  done
  printf '\n'
}

# --- Stage 3b: purge confirmation -------------------------------------------

# Returns 0 if the user typed literal "yes", 1 otherwise. Reads exactly one
# line from stdin. EOF or any other response (including "y", "YES", empty)
# is treated as refusal.
confirm_purge() {
  local sessions="$VAULT/claude-memory/sessions"
  printf 'About to delete %s distilled note file(s) under %s.\n' \
    "$SESSIONS_COUNT" "$sessions" >&2
  printf "Type 'yes' to confirm (anything else cancels): " >&2
  local reply=""
  if ! IFS= read -r reply; then
    printf '\n' >&2
    return 1
  fi
  [ "$reply" = "yes" ]
}

# --- Stage 4: act -----------------------------------------------------------

ACTIONS_DONE=()

_record_action() {
  # $1 = label (REMOVED / PRESERVED), $2 = entry
  ACTIONS_DONE+=("$1|$2")
}

act_default() {
  local projects="$VAULT/claude-memory/projects"
  if [ -L "$projects" ]; then
    unlink "$projects"
    _record_action "REMOVED" "symlink:$projects"
  fi
}

act_purge() {
  local sessions="$VAULT/claude-memory/sessions"
  local index="$VAULT/claude-memory/Index.md"
  if [ -d "$sessions" ]; then
    rm -rf "$sessions"
    _record_action "REMOVED" "sessions:$sessions"
  fi
  if [ -f "$index" ]; then
    rm -f "$index"
    _record_action "REMOVED" "index:$index"
  fi
}

act_preserve_sessions_and_index() {
  local sessions="$VAULT/claude-memory/sessions"
  local index="$VAULT/claude-memory/Index.md"
  if [ -d "$sessions" ]; then
    _record_action "PRESERVED" "sessions:$sessions"
  fi
  if [ -f "$index" ]; then
    _record_action "PRESERVED" "index:$index"
  fi
}

act_config() {
  rm -f "$CONFIG"
  _record_action "REMOVED" "config:$CONFIG"
  # Best-effort parent cleanup — only succeeds when empty.
  rmdir "$(dirname "$CONFIG")" 2>/dev/null || true
  # Best-effort claude-memory/ cleanup when purge emptied it.
  rmdir "$VAULT/claude-memory" 2>/dev/null || true
}

# --- Stage 5: --unregister-mcp ---------------------------------------------

act_unregister_mcp() {
  if ! command -v claude >/dev/null 2>&1; then
    printf 'MCP: claude not on PATH — skipping unregistration (non-fatal).\n'
    return 0
  fi

  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 claude mcp remove obsidian -s user >/dev/null 2>&1 || rc=$?
  else
    claude mcp remove obsidian -s user >/dev/null 2>&1 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'MCP: obsidian server unregistered.\n'
  elif [ "$rc" -eq 124 ]; then
    printf 'MCP: claude mcp remove timed out — skipping (non-fatal).\n'
  else
    printf 'MCP: claude mcp remove exited %s — skipping (non-fatal).\n' "$rc"
  fi
}

# --- Action rendering -------------------------------------------------------

print_actions_section() {
  [ "${#ACTIONS_DONE[@]}" -gt 0 ] || return 0
  printf 'ACTIONS\n'
  local row label entry kind value annotation color
  for row in "${ACTIONS_DONE[@]}"; do
    label="${row%%|*}"
    entry="${row#*|}"
    kind="${entry%%:*}"
    value="${entry#*:}"
    annotation=""
    case "$kind" in
      symlink)  annotation="" ;;
      sessions) annotation="  (${SESSIONS_COUNT} notes)" ;;
      *)        annotation="" ;;
    esac
    case "$label" in
      REMOVED)   color="$C_RED" ;;
      PRESERVED) color="$C_GREEN" ;;
      *)         color="" ;;
    esac
    printf '  %s%-10s%s %s%s\n' "$color" "$label" "$C_RESET" "$value" "$annotation"
  done
  printf '\n'
}

# --- Main -------------------------------------------------------------------

main() {
  parse_args "$@"

  discover
  validate

  compose_plan

  print_header
  print_vault_line "$VAULT"

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan_section "dry_run"
    printf 'Dry-run — no filesystem changes made.\n'
    exit 0
  fi

  print_plan_section "normal"

  local purged=0
  if [ "$PURGE" -eq 1 ]; then
    if confirm_purge; then
      purged=1
    else
      printf '\nSessions preserved — purge cancelled.\n\n'
      demote_sessions_to_preserve
    fi
  fi

  # Fixed action order (see design → Data Flow step 8):
  #   a. unlink projects symlink
  #   b. (if --purge confirmed) remove sessions + Index.md
  #   c. remove config file + cleanup empty parents
  #   d. (if --unregister-mcp) best-effort claude mcp remove
  act_default
  if [ "$purged" -eq 1 ]; then
    act_purge
  elif [ "$PURGE" -eq 1 ]; then
    act_preserve_sessions_and_index
  else
    act_preserve_sessions_and_index
  fi
  act_config

  if [ "$UNREGISTER_MCP" -eq 1 ]; then
    act_unregister_mcp
  fi

  print_actions_section

  if [ "$purged" -eq 1 ]; then
    printf 'Teardown complete. Distilled notes deleted.\n'
  else
    printf 'Teardown complete. Distilled notes preserved.\n'
  fi
  exit 0
}

main "$@"
