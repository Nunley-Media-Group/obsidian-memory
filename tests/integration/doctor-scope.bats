#!/usr/bin/env bats

# tests/integration/doctor-scope.bats — vault-doctor.sh reports scope_mode
# in human + --json output (FR10, AC8).

setup() {
  load '../helpers/scratch'
  DOCTOR="$PLUGIN_ROOT/scripts/vault-doctor.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export DOCTOR CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
}

teardown() { assert_home_untouched; }

_write_config() {
  local filter="${1:-.}"
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] }
}
EOF
  if [ "$filter" != "." ]; then
    local tmp
    tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
    jq --indent 2 "$filter" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

@test "default config → human output reports 'all (unscoped)'" {
  _write_config
  run "$DOCTOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope_mode"* ]]
  [[ "$output" == *"all (unscoped)"* ]]
}

@test "allowlist with counts → human output reports mode + counts" {
  _write_config '.projects = {"mode":"allowlist","excluded":["a"],"allowed":["b","c"]}'
  run "$DOCTOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope_mode"* ]]
  [[ "$output" == *"allowlist (excluded: 1, allowed: 2)"* ]]
}

@test "--json default → scope_mode entry has status=info, note='all (unscoped)'" {
  _write_config
  run "$DOCTOR" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq empty
  [ "$(printf '%s' "$output" | jq -r '.checks.scope_mode.status')" = "info" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.scope_mode.note')" = "all (unscoped)" ]
}

@test "--json allowlist → scope_mode note carries the formatted summary" {
  _write_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["b"]}'
  run "$DOCTOR" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.checks.scope_mode.status')" = "info" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.scope_mode.note')" = "allowlist (excluded: 0, allowed: 1)" ]
}

@test "scope_mode probe is INFO even with non-default mode (never FAIL)" {
  _write_config '.projects = {"mode":"allowlist","excluded":[],"allowed":[]}'
  run "$DOCTOR" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.checks.scope_mode.status')" = "info" ]
}
