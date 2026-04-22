#!/usr/bin/env bats

# tests/unit/vault-scope.bats — unit tests for scripts/vault-scope.sh.
#
# Every scenario runs under the bats scratch harness so $HOME is redirected
# to $BATS_TEST_TMPDIR/home and assert_home_untouched verifies that the
# operator's real ~/.claude/obsidian-memory/ was never touched.

setup() {
  load '../helpers/scratch'
  SCOPE="$PLUGIN_ROOT/scripts/vault-scope.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export SCOPE CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory"
}

teardown() { assert_home_untouched; }

_seed_config() {
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] }
}
EOF
}

# ---------------------------------------------------------------------------
# Happy-path verbs
# ---------------------------------------------------------------------------

@test "no args: prints status, exits 0" {
  _seed_config
  run "$SCOPE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: all"* ]]
  [[ "$output" == *"current:"* ]]
  [[ "$output" == *"excluded: (none)"* ]]
  [[ "$output" == *"allowed: (none)"* ]]
}

@test "status: same as no-args" {
  _seed_config
  run "$SCOPE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: all"* ]]
}

@test "current: prints current PWD's slug" {
  _seed_config
  ( cd "$BATS_TEST_TMPDIR" && mkdir -p my-project && cd my-project \
    && "$SCOPE" current ) > "$BATS_TEST_TMPDIR/cur.out"
  [ "$(cat "$BATS_TEST_TMPDIR/cur.out")" = "my-project" ]
}

@test "mode allowlist: flips mode + persists" {
  _seed_config
  run "$SCOPE" mode allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"projects.mode: all -> allowlist"* ]]
  [ "$(jq -r '.projects.mode' "$CONFIG")" = "allowlist" ]
}

@test "mode allowlist with empty allowed: warns on stderr but exits 0" {
  _seed_config
  run "$SCOPE" mode allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: allowlist mode with no allowed projects"* ]] \
    || [[ "$stderr" == *"WARNING: allowlist mode with no allowed projects"* ]]
}

@test "mode all: idempotent no-op when already 'all'" {
  _seed_config
  before="$(_stat_fingerprint "$CONFIG")"
  run "$SCOPE" mode all
  [ "$status" -eq 0 ]
  [[ "$output" == *"was already all"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

@test "exclude add: appends slug, persists, dedupes" {
  _seed_config
  run "$SCOPE" exclude add acme-client
  [ "$status" -eq 0 ]
  [[ "$output" == *'projects.excluded: added "acme-client"'* ]]
  [ "$(jq -r '.projects.excluded[0]' "$CONFIG")" = "acme-client" ]

  # Second add is a no-op
  run "$SCOPE" exclude add acme-client
  [ "$status" -eq 0 ]
  [[ "$output" == *'projects.excluded already contains "acme-client"'* ]]
  [ "$(jq -r '.projects.excluded | length' "$CONFIG")" = "1" ]
}

@test "exclude add: re-normalizes typed slug through om_slug" {
  _seed_config
  run "$SCOPE" exclude add Acme_Client
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects.excluded[0]' "$CONFIG")" = "acme-client" ]
}

@test "exclude add (no slug): defaults to current PWD's slug" {
  _seed_config
  mkdir -p "$BATS_TEST_TMPDIR/my-current"
  ( cd "$BATS_TEST_TMPDIR/my-current" && "$SCOPE" exclude add )
  [ "$(jq -r '.projects.excluded[0]' "$CONFIG")" = "my-current" ]
}

@test "exclude remove: drops slug; no-op when absent" {
  _seed_config
  "$SCOPE" exclude add acme >/dev/null
  "$SCOPE" exclude add beta >/dev/null

  run "$SCOPE" exclude remove acme
  [ "$status" -eq 0 ]
  [[ "$output" == *'projects.excluded: removed "acme"'* ]]
  [ "$(jq -r '.projects.excluded[0]' "$CONFIG")" = "beta" ]

  run "$SCOPE" exclude remove ghost
  [ "$status" -eq 0 ]
  [[ "$output" == *'projects.excluded did not contain "ghost"'* ]]
}

@test "exclude list: one slug per line" {
  _seed_config
  "$SCOPE" exclude add acme >/dev/null
  "$SCOPE" exclude add beta >/dev/null
  run "$SCOPE" exclude list
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "allow add/remove/list mirror the exclude verbs" {
  _seed_config
  run "$SCOPE" allow add obsidian-memory
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects.allowed[0]' "$CONFIG")" = "obsidian-memory"  ]
  run "$SCOPE" allow list
  [[ "$output" == *"obsidian-memory"* ]]
  run "$SCOPE" allow remove obsidian-memory
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects.allowed | length' "$CONFIG")" = "0" ]
}

# ---------------------------------------------------------------------------
# Mid-session caveat
# ---------------------------------------------------------------------------

@test "mid-session caveat: prints note when current project's bucket changes" {
  _seed_config
  mkdir -p "$BATS_TEST_TMPDIR/live-project"
  ( cd "$BATS_TEST_TMPDIR/live-project" && "$SCOPE" exclude add ) > "$BATS_TEST_TMPDIR/out"
  grep -q "Note: overrides apply to sessions that start AFTER this change" \
    "$BATS_TEST_TMPDIR/out"
}

# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

@test "missing config: stderr ERROR + exit 1" {
  rm -f "$CONFIG"
  run "$SCOPE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: config not found"* ]] \
    || [[ "$stderr" == *"ERROR: config not found"* ]]
}

@test "unknown verb: stderr ERROR + exit 2" {
  _seed_config
  run "$SCOPE" foobar
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown verb 'foobar'"* ]] \
    || [[ "$stderr" == *"unknown verb 'foobar'"* ]]
}

@test "unknown mode: stderr ERROR + exit 2" {
  _seed_config
  run "$SCOPE" mode unknown
  [ "$status" -eq 2 ]
}

@test "unknown sub-verb: stderr ERROR + exit 2" {
  _seed_config
  run "$SCOPE" exclude wat
  [ "$status" -eq 2 ]
}

@test "too many args to status: exit 2" {
  _seed_config
  run "$SCOPE" status extra
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Atomic write + key preservation
# ---------------------------------------------------------------------------

@test "preserve_unrelated_keys: customFoo round-trips after a scope mutation" {
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] },
  "customFoo": 42
}
EOF
  run "$SCOPE" exclude add acme
  [ "$status" -eq 0 ]
  [ "$(jq -r '.customFoo' "$CONFIG")" = "42" ]
  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
}

@test "preserve_2space_indent: rewritten config still uses 2-space indent" {
  _seed_config
  run "$SCOPE" exclude add acme
  [ "$status" -eq 0 ]
  grep -q '^  "' "$CONFIG"
}

@test "missing projects stanza: jq creates it; other keys survive" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  run "$SCOPE" exclude add acme
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects.excluded[0]' "$CONFIG")" = "acme" ]
  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
}

@test "shellcheck_clean: scope + session-start pass shellcheck (alongside _common.sh)" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  # Include _common.sh in the same invocation so shellcheck can follow the
  # `. _common.sh` source directive without -x.
  run shellcheck \
    "$PLUGIN_ROOT/scripts/_common.sh" \
    "$PLUGIN_ROOT/scripts/vault-scope.sh" \
    "$PLUGIN_ROOT/scripts/vault-session-start.sh"
  [ "$status" -eq 0 ]
}
