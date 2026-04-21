# tests/features/steps/doctor.sh — step definitions for
# specs/feature-doctor-health-check-skill/feature.gherkin.
#
# Exercises scripts/vault-doctor.sh end-to-end against the scratch harness.
# No real mutation of the operator's $HOME; all state lives under
# $BATS_TEST_TMPDIR.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

# Per-scenario state.
D_STDOUT=""
D_STDERR=""
D_RC=0
D_SNAPSHOT=""

_doctor_write_config() {
  local rag="$1" distill="$2"
  local cfg
  cfg="$(_config_path)"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":$rag},"distill":{"enabled":$distill}}
EOF
}

_doctor_install_safe_path_with_stub_claude() {
  local bindir="$BATS_TEST_TMPDIR/doctorbin"
  [ -f "$bindir/.initialized" ] && { PATH="$bindir"; export PATH; return 0; }

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

  rm -f "$bindir/claude"
  cat > "$bindir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  echo "obsidian: ws://localhost:22360"
  exit 0
fi
exit 0
CLAUDE
  chmod +x "$bindir/claude"

  : > "$bindir/.initialized"

  PATH="$bindir"
  export PATH
}

_doctor_baseline_healthy() {
  _doctor_write_config true true
  mkdir -p "$VAULT/claude-memory/sessions"
  mkdir -p "$HOME/.claude/projects"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
}

_doctor_tree_digest() {
  find "$VAULT" "$HOME/.claude/obsidian-memory" -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | xargs -0 cksum 2>/dev/null \
    | LC_ALL=C sort
}

_doctor_run() {
  D_STDERR="$(mktemp "$BATS_TEST_TMPDIR/doctor.err.XXXXXX")"
  D_STDOUT="$("$PLUGIN_ROOT/scripts/vault-doctor.sh" "$@" 2>"$D_STDERR")"
  D_RC=$?
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_a_safe_path_with_a_stub_claude_is_installed() {
  _doctor_install_safe_path_with_stub_claude
}

given_a_baseline_healthy_obsidian_memory_install() {
  _doctor_install_safe_path_with_stub_claude
  _doctor_baseline_healthy
}

given_no_config_file_exists() {
  rm -f "$(_config_path)"
  [ ! -e "$(_config_path)" ]
}

given_the_config_has_no_key() {
  # Arg: "vaultPath"
  local key="${1:-vaultPath}"
  mkdir -p "$(dirname "$(_config_path)")"
  # Write a config with everything EXCEPT the specified key.
  cat > "$(_config_path)" <<EOF
{"rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  # Guard against unused-arg warnings.
  [ -n "$key" ]
}

given_the_config_has_pointing_at_a_non_existent_directory() {
  # Arg: "vaultPath" (literal) — the key whose value should be bogus.
  mkdir -p "$(dirname "$(_config_path)")"
  cat > "$(_config_path)" <<EOF
{"vaultPath":"$BATS_TEST_TMPDIR/does-not-exist","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
}

given_is_not_on_path() {
  # Arg: binary name ("jq" / "claude" / "rg").
  local bin="${1:-}"
  [ -n "$bin" ] || return 1
  rm -f "$BATS_TEST_TMPDIR/doctorbin/$bin"
  ! command -v "$bin" >/dev/null 2>&1
}

given_the_projects_symlink_under_the_vault_is_broken() {
  rm -f "$VAULT/claude-memory/projects"
  ln -s "$BATS_TEST_TMPDIR/nonexistent-target" "$VAULT/claude-memory/projects"
}

given_the_sessions_directory_under_the_vault_is_missing() {
  rm -rf "$VAULT/claude-memory/sessions"
}

given_is_set_to_false_in_the_config() {
  # Arg: "rag.enabled" or "distill.enabled"
  local key="${1:-}"
  case "$key" in
    rag.enabled)     _doctor_write_config false true ;;
    distill.enabled) _doctor_write_config true  false ;;
    *) return 1 ;;
  esac
}

given_a_snapshot_of_the_scratch_vault_and_obsidian_memory_config_is_taken() {
  D_SNAPSHOT="$(_doctor_tree_digest)"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_i_run() {
  local cmd="${1:-}"
  case "$cmd" in
    "/obsidian-memory:doctor")        _doctor_run ;;
    "/obsidian-memory:doctor --json") _doctor_run "--json" ;;
    *) return 1 ;;
  esac
}

when_i_run_in_the_healthy_state() {
  when_i_run "$1"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_doctor_output_contains() {
  local needle="${1:-}"
  printf '%s' "$D_STDOUT" | grep -qF -- "$needle"
}

then_the_doctor_output_does_not_contain() {
  local needle="${1:-}"
  ! printf '%s' "$D_STDOUT" | grep -qF -- "$needle"
}

then_the_doctor_exit_code_is_0() {
  [ "$D_RC" -eq 0 ]
}

then_the_doctor_exit_code_is_non_zero() {
  [ "$D_RC" -ne 0 ]
}

then_the_doctor_output_is_a_single_valid_json_object() {
  printf '%s' "$D_STDOUT" | jq empty
}

then_the_json_object_has_top_level_equal_to_true() {
  # Arg: "ok"
  local key="${1:-ok}"
  [ "$(printf '%s' "$D_STDOUT" | jq -r --arg k "$key" '.[$k]')" = "true" ]
}

then_the_json_object_has_top_level_equal_to_false() {
  local key="${1:-ok}"
  [ "$(printf '%s' "$D_STDOUT" | jq -r --arg k "$key" '.[$k]')" = "false" ]
}

then_the_json_object_has_check_with_status() {
  # Args: "config", "ok"
  local check="$1" status="$2"
  [ "$(printf '%s' "$D_STDOUT" | jq -r --arg c "$check" '.checks[$c].status')" = "$status" ]
}

then_the_json_object_has_check_with_hint_containing() {
  # Args: "vault_path", "/obsidian-memory:setup"
  local check="$1" needle="$2"
  printf '%s' "$D_STDOUT" | jq -r --arg c "$check" '.checks[$c].hint' | grep -qF -- "$needle"
}

then_the_scratch_vault_snapshot_is_unchanged() {
  local current
  current="$(_doctor_tree_digest)"
  [ "$current" = "$D_SNAPSHOT" ]
}
