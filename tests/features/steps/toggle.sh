# tests/features/steps/toggle.sh — step definitions for
# specs/feature-add-obsidian-memory-toggle-skill-for-rag-distill-enable-flags/feature.gherkin (#4).
#
# Exercises scripts/vault-toggle.sh end-to-end against the scratch harness.
# Every filesystem mutation lives under $BATS_TEST_TMPDIR — the operator's
# real ~/.claude is never touched.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153
# SC2154/SC2153 fire for VAULT/HOME/PLUGIN_ROOT/BATS_TEST_TMPDIR — all
# exported by tests/helpers/scratch.bash before this file is sourced.

TG_STDOUT=""
TG_STDERR=""
TG_RC=0
TG_SNAPSHOT=""

_toggle_script() {
  printf '%s' "$PLUGIN_ROOT/scripts/vault-toggle.sh"
}

# Write a baseline healthy config with both flags set to the given values.
_toggle_write_baseline() {
  local rag="${1:-true}" distill="${2:-true}"
  mkdir -p "$(dirname "$(_config_path)")"
  cat > "$(_config_path)" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": {
    "enabled": $rag
  },
  "distill": {
    "enabled": $distill
  }
}
EOF
}

# BSD / GNU stat abstraction — returns "<inode>-<mtime>".
_toggle_stat_fingerprint() {
  if stat -f '%i-%m' "$1" 2>/dev/null; then return 0; fi
  stat -c '%i-%Y' "$1"
}

# Parse a "vault-toggle.sh <args>" command line into an argv array passed to
# the script. No quoting semantics are needed — the gherkin authors only pass
# simple tokens (rag, off, status, foobar).
_toggle_run_from_cmdline() {
  local cmd="$1"
  local rest="${cmd#vault-toggle.sh}"
  # Trim leading whitespace.
  rest="${rest# }"
  TG_STDERR="$(mktemp "$BATS_TEST_TMPDIR/toggle.err.XXXXXX")"
  local script
  script="$(_toggle_script)"
  if [ -z "$rest" ]; then
    TG_STDOUT="$("$script" 2>"$TG_STDERR")"
  else
    # shellcheck disable=SC2086
    TG_STDOUT="$("$script" $rest 2>"$TG_STDERR")"
  fi
  TG_RC=$?
}

# Install a PATH-shadowed stub for $1 whose body is whatever is piped in via
# the heredoc in the caller. Used by the "a 'mv' stub that always exits
# non-zero" step.
_toggle_install_stub() {
  local binary="$1"
  local bindir="$BATS_TEST_TMPDIR/togglebin"
  if [ ! -f "$bindir/.initialized" ]; then
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
    : > "$bindir/.initialized"
  fi

  rm -f "$bindir/$binary"
  cat > "$bindir/$binary" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$bindir/$binary"
  PATH="$bindir"
  export PATH
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

# Given obsidian-memory is installed at "$PLUGIN_ROOT"
given_obsidian_memory_is_installed_at() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  [ -x "$path/scripts/vault-toggle.sh" ]
}

# Given a config at "<path>" with "<key>" set to true
given_a_config_at_with_set_to_true() {
  local path="${1:-}" key="${2:-}"
  [ -n "$path" ] && [ -n "$key" ] || return 1
  _toggle_write_baseline true true
  _config_set_field "$key" true
}

# Given a config at "<path>" with "<key>" set to false
given_a_config_at_with_set_to_false() {
  local path="${1:-}" key="${2:-}"
  [ -n "$path" ] && [ -n "$key" ] || return 1
  _toggle_write_baseline true true
  _config_set_field "$key" false
}

# Given a config with "<key>" set to true
given_a_config_with_set_to_true() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  _toggle_write_baseline true true
  _config_set_field "$key" true
}

# Given a config with "rag.enabled" true and "distill.enabled" false
given_a_config_with_true_and_false() {
  local key1="${1:-}" key2="${2:-}"
  [ -n "$key1" ] && [ -n "$key2" ] || return 1
  _toggle_write_baseline true true
  _config_set_field "$key1" true
  _config_set_field "$key2" false
}

# Given a config with "rag.enabled" true and "distill.enabled" true
given_a_config_with_true_and_true() {
  local key1="${1:-}" key2="${2:-}"
  [ -n "$key1" ] && [ -n "$key2" ] || return 1
  _toggle_write_baseline true true
  _config_set_field "$key1" true
  _config_set_field "$key2" true
}

# And a snapshot of the config file's mtime and inode
given_a_snapshot_of_the_config_file_s_mtime_and_inode() {
  TG_SNAPSHOT="$(_toggle_stat_fingerprint "$(_config_path)")"
}

# Given there is no config file at "<path>"
given_there_is_no_config_file_at() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  rm -f "$path"
  [ ! -e "$path" ]
}

# And the config contains an unrelated user key "customFoo" set to 42
given_the_config_contains_an_unrelated_user_key_set_to_42() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  _config_set_field "$key" 42
}

# And a "mv" stub on PATH that always exits non-zero
given_a_stub_on_path_that_always_exits_non_zero() {
  local binary="${1:-}"
  [ -n "$binary" ] || return 1
  _toggle_install_stub "$binary"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

# When the user runs "<command line>"
when_the_user_runs() {
  local cmd="${1:-}"
  _toggle_run_from_cmdline "$cmd"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_exit_code_is_0() {
  [ "$TG_RC" -eq 0 ]
}

then_the_exit_code_is_1() {
  [ "$TG_RC" -eq 1 ]
}

then_the_exit_code_is_2() {
  [ "$TG_RC" -eq 2 ]
}

# And stdout contains "<needle>"
then_stdout_contains() {
  local needle="${1:-}"
  printf '%s' "$TG_STDOUT" | grep -qF -- "$needle"
}

# And stderr contains "<needle>"
then_stderr_contains() {
  local needle="${1:-}"
  grep -qF -- "$needle" "$TG_STDERR"
}

# And the config at "<path>" has "<key>" set to false
then_the_config_at_has_set_to_false() {
  local path="${1:-}" key="${2:-}"
  [ -n "$path" ] && [ -n "$key" ] || return 1
  [ "$(jq -r --arg k "$key" 'getpath($k | split("."))' "$path")" = "false" ]
}

# And the config has "<key>" set to true
then_the_config_has_set_to_true() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  [ "$(jq -r --arg k "$key" 'getpath($k | split("."))' "$(_config_path)")" = "true" ]
}

# And the config file's mtime and inode match the snapshot
then_the_config_file_s_mtime_and_inode_match_the_snapshot() {
  local current
  current="$(_toggle_stat_fingerprint "$(_config_path)")"
  [ "$current" = "$TG_SNAPSHOT" ]
}

# And no file exists at "<path>"
then_no_file_exists_at() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  [ ! -e "$path" ]
}

# And the config at "<path>" still has "<key>" set to true
then_the_config_at_still_has_set_to_true() {
  local path="${1:-}" key="${2:-}"
  [ -n "$path" ] && [ -n "$key" ] || return 1
  [ "$(jq -r --arg k "$key" 'getpath($k | split("."))' "$path")" = "true" ]
}

# And the config still has "<key>" set to 42
then_the_config_still_has_set_to_42() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  [ "$(jq -r --arg k "$key" 'getpath($k | split("."))' "$(_config_path)")" = "42" ]
}

# And no ".tmp" artifact remains in "<dir>"
then_no_artifact_remains_in() {
  local pattern="${1:-.tmp}" dir="${2:-}"
  [ -n "$dir" ] || return 1
  # Any file in $dir whose name contains $pattern fails the assertion.
  local hits
  hits="$(find "$dir" -mindepth 1 -maxdepth 1 -name "*${pattern}*" 2>/dev/null | head -n 1)"
  [ -z "$hits" ]
}

# And the config uses 2-space indentation
then_the_config_uses_2_space_indentation() {
  local cfg
  cfg="$(_config_path)"
  # Two-space body lines ("  \"<key>\": ...") and four-space nested lines
  # ("    \"enabled\": ...") are both produced by `jq --indent 2`.
  grep -q '^  "' "$cfg" && grep -q '^    "enabled"' "$cfg"
}
