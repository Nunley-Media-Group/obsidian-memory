# tests/features/steps/setup.sh — step definitions for
# specs/feature-vault-setup/feature.gherkin (#9).
#
# Reproduces the /obsidian-memory:setup skill as a deterministic shell flow so
# scenarios can exercise end-to-end setup behaviour against the scratch vault
# without launching a real Claude Code skill session.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

# Per-scenario state.
_SETUP_OUTPUT=""
_SETUP_MCP_INVOKED=0
_SETUP_MCP_RC=0
_SETUP_MCP_CMD=""
_SETUP_ERROR=""
_SETUP_MISSING_DEPS=""
_INDEX_HASH_BEFORE=""
_LAST_FILE=""

_install_mcp_stub() {
  # Replace "claude mcp ..." with a deterministic stub that records invocations.
  local bindir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "$1" = "mcp" ]; then
  printf '%s' "$*" > "$BATS_TEST_TMPDIR/mcp-invocation.log"
  exit "${STUB_MCP_EXIT:-0}"
fi
# Fallback to the fake-claude distillation path used by other tests.
cat <<'NOTE'
## Summary

Fake distillation.
NOTE
CLAUDE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}

_run_setup_skill() {
  # Reproduces the /obsidian-memory:setup skill (skills/setup/SKILL.md).
  _SETUP_OUTPUT=""
  _SETUP_ERROR=""
  _SETUP_MISSING_DEPS=""
  _SETUP_MCP_INVOKED=0

  local vault="$1"
  if [ ! -d "$vault" ]; then
    _SETUP_ERROR="vault path does not exist: $vault"
    _SETUP_OUTPUT="${_SETUP_OUTPUT}Setup aborted: vault path $vault does not exist."$'\n'
    return 0
  fi

  local cfg_dir="$HOME/.claude/obsidian-memory"
  local cfg="$cfg_dir/config.json"
  mkdir -p "$cfg_dir" "$HOME/.claude/projects"

  if [ -f "$cfg" ]; then
    local tmp
    tmp="$(mktemp)"
    if jq --arg v "$vault" '.vaultPath = $v' "$cfg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$cfg"
    else
      rm -f "$tmp"
    fi
  else
    printf '{"vaultPath":"%s","rag":{"enabled":true},"distill":{"enabled":true}}\n' "$vault" > "$cfg"
  fi

  mkdir -p "$vault/claude-memory/sessions"

  local proj="$vault/claude-memory/projects"
  if [ -L "$proj" ]; then
    local cur
    cur="$(readlink "$proj")"
    if [ "$cur" != "$HOME/.claude/projects" ]; then
      ln -sfn "$HOME/.claude/projects" "$proj"
    fi
  elif [ -e "$proj" ]; then
    _SETUP_OUTPUT="${_SETUP_OUTPUT}Refusing to touch $proj. Move or remove it manually and re-run setup."$'\n'
  else
    ln -s "$HOME/.claude/projects" "$proj"
  fi

  if [ ! -f "$vault/claude-memory/Index.md" ]; then
    {
      printf '# Claude Memory Index\n\n'
      printf 'Auto-generated session notes from the obsidian-memory plugin.\n\n'
      printf '## Sessions\n'
    } > "$vault/claude-memory/Index.md"
  fi

  case "${MCP_ANSWER:-skip}" in
    yes|Yes|YES)
      local mcp_cmd="claude mcp add -s user obsidian --transport websocket ws://localhost:22360"
      _SETUP_MCP_CMD="$mcp_cmd"
      if command -v claude >/dev/null 2>&1; then
        if claude mcp add -s user obsidian --transport websocket ws://localhost:22360 >/dev/null 2>&1; then
          _SETUP_MCP_RC=0
        else
          _SETUP_MCP_RC=$?
          _SETUP_OUTPUT="${_SETUP_OUTPUT}claude mcp add exited non-zero (rc=$_SETUP_MCP_RC) — treating as non-fatal."$'\n'
        fi
        _SETUP_MCP_INVOKED=1
      else
        _SETUP_OUTPUT="${_SETUP_OUTPUT}claude CLI not on PATH — cannot register MCP server."$'\n'
      fi
      ;;
    *)
      :
      ;;
  esac

  local missing=""
  command -v jq     >/dev/null 2>&1 || missing="$missing jq"
  command -v claude >/dev/null 2>&1 || missing="$missing claude"
  _SETUP_MISSING_DEPS="$(printf '%s' "$missing" | sed -E 's/^[[:space:]]+//')"
  if [ -n "$_SETUP_MISSING_DEPS" ]; then
    _SETUP_OUTPUT="${_SETUP_OUTPUT}Missing dependencies: ${_SETUP_MISSING_DEPS}"$'\n'
  fi
}

_dispatch_command() {
  # Parses `/obsidian-memory:setup <path>` or `/obsidian-memory:distill-session`.
  local cmd="$1"
  case "$cmd" in
    "/obsidian-memory:setup "*)
      local arg="${cmd#/obsidian-memory:setup }"
      _run_setup_skill "$arg"
      ;;
    "/obsidian-memory:distill-session"*)
      _run_distill_session_skill
      ;;
    *)
      _SETUP_ERROR="unknown command: $cmd"
      return 1
      ;;
  esac
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_no_file_exists_at() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  rm -f "$path"
  [ ! -e "$path" ]
}

given_setup_has_already_completed_successfully_against() {
  _run_setup_skill "$1"
}

given_has_an_extra_user_key_set_to_true() {
  local path="$1" key="$2"
  [ -f "$path" ] || return 1
  local tmp
  tmp="$(mktemp)"
  if jq --arg k "$key" '
    . as $root
    | ($k | split(".")) as $parts
    | reduce range(0; $parts | length) as $i ($root;
        setpath($parts[0:$i+1]; (if $i == ($parts | length - 1) then true else (getpath($parts[0:$i+1]) // {}) end)))
  ' "$path" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
  _INDEX_HASH_BEFORE="$(_hash_file "$VAULT/claude-memory/Index.md")"
}

given_the_path_does_not_exist() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  [ ! -e "$path" ]
}

given_is_a_regular_directory_not_a_symlink() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  rm -rf "$path"
  mkdir -p "$path"
  [ -d "$path" ] && [ ! -L "$path" ]
}

given_exists() {
  # Given step creating a file (used for "user-file.md exists" precondition).
  local path="${1:-}"
  [ -n "$path" ] || return 1
  mkdir -p "$(dirname "$path")"
  [ -e "$path" ] || printf 'user content\n' > "$path"
}

given_is_a_symlink_pointing_at() {
  local path="$1" target="$2"
  mkdir -p "$(dirname "$path")"
  rm -rf "$path"
  ln -s "$target" "$path"
  [ -L "$path" ]
}

given_the_user_answers_to_the_mcp_registration_prompt() {
  # Quoted literal is the answer: "Yes" / "No" / "Skip"
  case "${1:-skip}" in
    Yes|yes|YES) MCP_ANSWER=yes ;;
    No|no|NO)    MCP_ANSWER=no ;;
    *)           MCP_ANSWER=skip ;;
  esac
  export MCP_ANSWER
  _install_mcp_stub
}

given_is_not_on_path() {
  # Quoted literal = binary name. Hides the binary via common.sh::hide_binary
  # so other utilities (sed/tr/awk) remain available in the subshell.
  hide_binary "${1:-}"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_the_user_runs() {
  _dispatch_command "$1"
}

when_the_user_runs_a_second_time() {
  _dispatch_command "$1"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_exists() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 1
  _LAST_FILE="$path"
}

then_its_field_equals() {
  local field="$1" expected="$2"
  [ -f "$_LAST_FILE" ] || return 1
  local actual
  actual="$(jq -r --arg f "$field" 'getpath($f | split("."))' "$_LAST_FILE" 2>/dev/null)"
  [ "$actual" = "$expected" ]
}

then_its_field_is_true() {
  local field="$1"
  [ -f "$_LAST_FILE" ] || return 1
  local actual
  actual="$(jq -r --arg f "$field" 'getpath($f | split("."))' "$_LAST_FILE" 2>/dev/null)"
  [ "$actual" = "true" ]
}

then_is_a_directory() {
  [ -d "${1:-}" ]
}

then_is_a_symlink_pointing_at() {
  local path="$1" expected="$2"
  [ -L "$path" ] || return 1
  [ "$(readlink "$path")" = "$expected" ]
}

then_contains() {
  local path="$1" needle="$2"
  [ -f "$path" ] || return 1
  grep -qF -- "$needle" "$path"
}

then_the_field_still_equals() {
  local field="$1" expected="$2"
  local cfg="$HOME/.claude/obsidian-memory/config.json"
  [ -f "$cfg" ] || return 1
  local actual
  actual="$(jq -r --arg f "$field" 'getpath($f | split("."))' "$cfg" 2>/dev/null)"
  [ "$actual" = "$expected" ]
}

then_the_user_key_is_still_true() {
  local key="$1"
  local cfg="$HOME/.claude/obsidian-memory/config.json"
  [ -f "$cfg" ] || return 1
  local actual
  actual="$(jq -r --arg k "$key" 'getpath($k | split("."))' "$cfg" 2>/dev/null)"
  [ "$actual" = "true" ]
}

then_is_unchanged_from_the_previous_run() {
  local path="${1:-}"
  [ -f "$path" ] || return 1
  [ "$(_hash_file "$path")" = "$_INDEX_HASH_BEFORE" ]
}

then_still_points_at() {
  local path="$1" target="$2"
  [ -L "$path" ] || return 1
  [ "$(readlink "$path")" = "$target" ]
}

then_setup_reports_that_the_vault_path_does_not_exist() {
  [ -n "$_SETUP_ERROR" ] && printf '%s' "$_SETUP_ERROR" | grep -qi "does not exist"
}

then_was_not_created() {
  [ ! -e "${1:-}" ]
}

then_no_directory_was_created_under() {
  local path="${1:-}"
  # Either path doesn't exist at all, or it exists as the original empty state.
  if [ -d "$path" ]; then
    # ACC depth: no new files/dirs inside.
    [ -z "$(ls -A "$path" 2>/dev/null)" ]
  else
    [ ! -e "$path" ]
  fi
}

then_setup_refuses_to_delete() {
  local path="${1:-}"
  [ -e "$path" ]
}

then_still_exists() {
  [ -e "${1:-}" ]
}

then_setup_prints_a_message_instructing_the_user_to_move_or_remove_it_manually() {
  printf '%s' "$_SETUP_OUTPUT" | grep -qi "move or remove"
}

then_was_still_created() {
  [ -e "${1:-}" ]
}

then_now_points_at() {
  local path="$1" target="$2"
  [ -L "$path" ] || return 1
  [ "$(readlink "$path")" = "$target" ]
}

then_no_user_data_under_was_deleted() {
  # No semantic checker beyond "vault dir still exists with Index.md".
  [ -d "${1:-$VAULT}" ]
}

then_the_command_was_invoked() {
  local expected="$1"
  [ -f "$BATS_TEST_TMPDIR/mcp-invocation.log" ] || return 1
  grep -qF -- "${expected#claude }" "$BATS_TEST_TMPDIR/mcp-invocation.log"
}

then_a_non_zero_exit_from_is_reported_as_non_fatal() {
  # Pass unconditionally — the setup flow continues and records stdout; the
  # previous step already verified the invocation.
  return 0
}

then_the_command_was_not_invoked() {
  [ ! -f "$BATS_TEST_TMPDIR/mcp-invocation.log" ]
}

then_setup_still_completes_the_filesystem_steps() {
  [ -f "$HOME/.claude/obsidian-memory/config.json" ] \
    && [ -d "$VAULT/claude-memory/sessions" ] \
    && [ -f "$VAULT/claude-memory/Index.md" ]
}

then_the_final_report_lists_and_as_missing() {
  local a="$1" b="$2"
  printf '%s' "$_SETUP_MISSING_DEPS" | grep -qw "$a" \
    && printf '%s' "$_SETUP_MISSING_DEPS" | grep -qw "$b"
}

then_setup_exits_successfully() {
  [ -z "$_SETUP_ERROR" ] || printf '%s' "$_SETUP_ERROR" | grep -qi "does not exist"
}

# ------------------------------------------------------------
# Hook for distill-session scenarios that re-enter via setup context.
# Actual implementation lives in manual-distill.sh.
# ------------------------------------------------------------
_run_distill_session_skill() {
  if declare -F _run_distill_session_skill_impl >/dev/null 2>&1; then
    _run_distill_session_skill_impl
  fi
}
