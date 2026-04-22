# tests/features/steps/teardown.sh — step definitions for
# specs/feature-add-obsidian-memory-teardown-skill/feature.gherkin (#3).
#
# Exercises scripts/vault-teardown.sh end-to-end against the scratch harness.
# Every filesystem mutation lives under $BATS_TEST_TMPDIR — the operator's
# real ~/.claude and real vault are never touched.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

# Per-scenario state.
T_STDOUT=""
T_STDERR=""
T_RC=0

_teardown_config_path() {
  printf '%s' "$HOME/.claude/obsidian-memory/config.json"
}

_teardown_install_safe_path_with_stub_claude() {
  local bindir="$BATS_TEST_TMPDIR/teardownbin"
  if [ -f "$bindir/.initialized" ]; then
    PATH="$bindir"
    export PATH
    return 0
  fi

  mkdir -p "$bindir"
  local d f name
  local IFS_SAVED="$IFS"
  IFS=':'
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      name="$(basename "$f")"
      [ -e "$bindir/$name" ] && continue
      ln -s "$f" "$bindir/$name" 2>/dev/null || true
    done
  done
  IFS="$IFS_SAVED"

  T_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  export T_CLAUDE_LOG
  : > "$T_CLAUDE_LOG"

  _teardown_install_stub_claude succeed
  : > "$bindir/.initialized"

  PATH="$bindir"
  export PATH
}

# Install a stub claude with the requested behavior for `mcp remove obsidian`.
# Mode:
#   succeed — exit 0, log the invocation
#   fail    — exit 1, log the invocation
_teardown_install_stub_claude() {
  local mode="${1:-succeed}"
  local bindir="$BATS_TEST_TMPDIR/teardownbin"
  local exit_rc
  case "$mode" in
    succeed) exit_rc=0 ;;
    fail)    exit_rc=1 ;;
    *) return 1 ;;
  esac

  rm -f "$bindir/claude"
  cat > "$bindir/claude" <<CLAUDE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T_CLAUDE_LOG"
exit $exit_rc
CLAUDE
  chmod +x "$bindir/claude"
}

_teardown_baseline_healthy() {
  mkdir -p "$HOME/.claude/projects" "$HOME/.claude/obsidian-memory"
  cat > "$(_teardown_config_path)" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
  printf '# Claude Memory Index\n\n## Sessions\n' > "$VAULT/claude-memory/Index.md"
}

_teardown_seed_sessions() {
  local count="$1" i
  mkdir -p "$VAULT/claude-memory/sessions/proj"
  for (( i = 1; i <= count; i++ )); do
    printf 'note %d\n' "$i" > "$VAULT/claude-memory/sessions/proj/note-$i.md"
  done
  snapshot_sessions
}

_teardown_run() {
  local stdin_input="${1-}"
  shift || true

  T_STDERR="$(mktemp "$BATS_TEST_TMPDIR/teardown.err.XXXXXX")"
  local script="$PLUGIN_ROOT/scripts/vault-teardown.sh"
  if [ "$stdin_input" = "__NO_STDIN__" ]; then
    if [ "$#" -gt 0 ]; then
      T_STDOUT="$("$script" "$@" </dev/null 2>"$T_STDERR")"
    else
      T_STDOUT="$("$script" </dev/null 2>"$T_STDERR")"
    fi
  else
    # printf '%s\n' ensures the purge-prompt read sees a complete line —
    # command substitution on a caller-supplied `yes` stripped the trailing
    # newline, which triggered the EOF-cancels-purge branch in the script.
    if [ "$#" -gt 0 ]; then
      T_STDOUT="$(printf '%s\n' "$stdin_input" | "$script" "$@" 2>"$T_STDERR")"
    else
      T_STDOUT="$(printf '%s\n' "$stdin_input" | "$script" 2>"$T_STDERR")"
    fi
  fi
  T_RC=$?
}

# Strip the "/obsidian-memory:teardown" prefix, leaving the flag string.
_teardown_flags() {
  local cmd="$1"
  printf '%s' "${cmd#"/obsidian-memory:teardown"}"
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_a_safe_path_with_a_stub_claude_is_installed() {
  _teardown_install_safe_path_with_stub_claude
}

given_a_baseline_healthy_obsidian_memory_install() {
  _teardown_install_safe_path_with_stub_claude
  _teardown_baseline_healthy
  snapshot_sessions
}

# The gherkin bakes the sessions count into the step phrase (3/4/5 are
# bare numbers, not quoted literals), so each count needs its own function.
given_the_sessions_directory_contains_3_distilled_note_files() {
  _teardown_seed_sessions 3
}

given_the_sessions_directory_contains_4_distilled_note_files() {
  _teardown_seed_sessions 4
}

given_the_sessions_directory_contains_5_distilled_note_files() {
  _teardown_seed_sessions 5
}

given_a_stub_claude_that_succeeds_on() {
  _teardown_install_stub_claude succeed
  : > "$T_CLAUDE_LOG"
}

given_a_stub_claude_that_exits_non_zero_on() {
  _teardown_install_stub_claude fail
  : > "$T_CLAUDE_LOG"
}

given_a_stub_claude_that_records_every_invocation() {
  _teardown_install_stub_claude succeed
  : > "$T_CLAUDE_LOG"
}

given_the_vault_s_directory_has_been_removed() {
  # Arg: "claude-memory"
  rm -rf "$VAULT/claude-memory"
}

given_the_projects_entry_under_the_vault_is_replaced_with_a_regular_directory() {
  rm -rf "$VAULT/claude-memory/projects"
  mkdir -p "$VAULT/claude-memory/projects/subdir"
  printf 'marker\n' > "$VAULT/claude-memory/projects/keep.txt"
}

given_the_projects_symlink_under_the_vault_targets_an_unrelated_directory() {
  rm -f "$VAULT/claude-memory/projects"
  mkdir -p "$BATS_TEST_TMPDIR/unrelated"
  ln -s "$BATS_TEST_TMPDIR/unrelated" "$VAULT/claude-memory/projects"
}

given_the_configured_vaultpath_has_been_moved_to_a_non_existent_directory() {
  local bogus="$BATS_TEST_TMPDIR/vault-moved-away"
  mkdir -p "$(dirname "$(_teardown_config_path)")"
  cat > "$(_teardown_config_path)" <<EOF
{"vaultPath":"$bogus","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
}

given_no_obsidian_memory_config_exists() {
  _teardown_install_safe_path_with_stub_claude
  rm -rf "$HOME/.claude/obsidian-memory"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_i_run() {
  local flags
  flags="$(_teardown_flags "${1:-/obsidian-memory:teardown}")"
  # shellcheck disable=SC2086
  _teardown_run "" $flags
}

when_i_run_and_type_at_the_confirmation_prompt() {
  # Args: "/obsidian-memory:teardown --purge", "yes"|"y"|"YES"
  local flags
  flags="$(_teardown_flags "$1")"
  # shellcheck disable=SC2086
  _teardown_run "$(printf '%s\n' "$2")" $flags
}

when_i_run_and_type_an_empty_line_at_the_confirmation_prompt() {
  # Arg: "/obsidian-memory:teardown --purge"
  local flags
  flags="$(_teardown_flags "$1")"
  # shellcheck disable=SC2086
  _teardown_run "$(printf '\n')" $flags
}

when_i_run_with_no_input_on_stdin() {
  # Arg: "/obsidian-memory:teardown --purge" (also used by --dry-run variants)
  local flags
  flags="$(_teardown_flags "$1")"
  # shellcheck disable=SC2086
  _teardown_run "__NO_STDIN__" $flags
}

when_i_run_again() {
  when_i_run "$@"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_teardown_output_contains() {
  local needle="${1:-}"
  printf '%s' "$T_STDOUT" | grep -qF -- "$needle"
}

then_the_teardown_output_does_not_contain_a_prompt() {
  # The "Type 'yes'" prompt is written to stderr, not stdout. Stream both.
  local combined
  combined="$T_STDOUT"$'\n'"$(cat "$T_STDERR" 2>/dev/null || true)"
  ! printf '%s' "$combined" | grep -qF "Type 'yes'"
}

then_the_teardown_output_contains_the_sessions_directory_path_under_would_remove() {
  local sessions="$VAULT/claude-memory/sessions"
  printf '%s' "$T_STDOUT" | grep -qE "WOULD REMOVE[[:space:]]+${sessions}"
}

then_the_teardown_exit_code_is_0() {
  [ "$T_RC" -eq 0 ]
}

then_the_teardown_exit_code_is_non_zero() {
  [ "$T_RC" -ne 0 ]
}

then_the_config_file_at_no_longer_exists() {
  [ ! -e "$(_teardown_config_path)" ]
}

then_the_config_file_at_still_exists() {
  [ -f "$(_teardown_config_path)" ]
}

then_the_projects_symlink_under_the_vault_no_longer_exists() {
  [ ! -e "$VAULT/claude-memory/projects" ] && [ ! -L "$VAULT/claude-memory/projects" ]
}

then_the_projects_symlink_under_the_vault_still_exists() {
  [ -L "$VAULT/claude-memory/projects" ]
}

then_the_projects_directory_under_the_vault_is_not_removed() {
  [ -d "$VAULT/claude-memory/projects" ]
}

then_the_sessions_directory_under_the_vault_is_preserved_byte_for_byte() {
  [ -d "$VAULT/claude-memory/sessions" ] || return 1
  assert_sessions_untouched
}

then_the_sessions_directory_under_the_vault_no_longer_exists() {
  [ ! -e "$VAULT/claude-memory/sessions" ]
}

then_the_index_md_under_the_vault_is_preserved_byte_for_byte() {
  [ -f "$VAULT/claude-memory/Index.md" ] || return 1
  assert_sessions_untouched
}

then_the_index_md_under_the_vault_no_longer_exists() {
  [ ! -e "$VAULT/claude-memory/Index.md" ]
}

then_the_stub_claude_was_invoked_with() {
  local needle="${1:-}"
  [ -s "$T_CLAUDE_LOG" ] || return 1
  grep -qF -- "$needle" "$T_CLAUDE_LOG"
}

then_the_stub_claude_was_not_invoked() {
  [ ! -s "$T_CLAUDE_LOG" ]
}

then_no_file_under_is_created() {
  # Arg: "~/.claude/obsidian-memory"
  [ ! -e "$HOME/.claude/obsidian-memory" ] || {
    [ -z "$(find "$HOME/.claude/obsidian-memory" -mindepth 1 -print -quit 2>/dev/null)" ]
  }
}

then_the_second_run_s_output_contains() {
  local needle="${1:-}"
  printf '%s' "$T_STDOUT" | grep -qF -- "$needle"
}

then_the_second_run_s_exit_code_is_0() {
  [ "$T_RC" -eq 0 ]
}
