#!/usr/bin/env bats

# tests/integration/toggle.bats — end-to-end coverage of vault-toggle.sh.
#
# Every scenario runs under the bats scratch harness (tests/helpers/scratch)
# so $HOME is redirected to $BATS_TEST_TMPDIR/home and assert_home_untouched
# verifies that the operator's real ~/.claude/obsidian-memory/ was never
# touched during the run.
#
# Covers T007 in specs/feature-add-obsidian-memory-toggle-skill-for-rag-distill-enable-flags/tasks.md.

setup() {
  load '../helpers/scratch'

  TOGGLE="$PLUGIN_ROOT/scripts/vault-toggle.sh"
  export TOGGLE

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG

  mkdir -p "$HOME/.claude/obsidian-memory"
}

teardown() {
  assert_home_untouched
}

_write_config() {
  # $1 = rag.enabled (true/false), $2 = distill.enabled (true/false)
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": {
    "enabled": $1
  },
  "distill": {
    "enabled": $2
  }
}
EOF
}

_write_config_with_custom() {
  # $1 = rag.enabled, $2 = distill.enabled, emits an extra "customFoo": 42 key.
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": {
    "enabled": $1
  },
  "distill": {
    "enabled": $2
  },
  "customFoo": 42
}
EOF
}

# Inode + mtime are captured together so "config unchanged" assertions can
# prove both that the bytes did not change and that the file was not replaced
# by a rename-in-place that preserved content but churned metadata.
_stat_fingerprint() {
  # macOS BSD stat vs. Linux GNU stat — use POSIX fallback syntax.
  if stat -f '%i-%m' "$1" 2>/dev/null; then
    return 0
  fi
  stat -c '%i-%Y' "$1"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

@test "status: prints both flags, exit 0" {
  _write_config true false
  run "$TOGGLE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag.enabled: true"* ]]
  [[ "$output" == *"distill.enabled: false"* ]]
}

@test "status_shorthand: no args is equivalent to 'status'" {
  _write_config false true
  before="$(_stat_fingerprint "$CONFIG")"
  run "$TOGGLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag.enabled: false"* ]]
  [[ "$output" == *"distill.enabled: true"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Explicit set
# ---------------------------------------------------------------------------

@test "rag_off: flips rag.enabled true → false, exit 0, persists to disk" {
  _write_config true true
  run "$TOGGLE" rag off
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag.enabled: true -> false"* ]]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "false" ]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "true" ]
}

@test "distill_on: flips distill.enabled false → true" {
  _write_config true false
  run "$TOGGLE" distill on
  [ "$status" -eq 0 ]
  [[ "$output" == *"distill.enabled: false -> true"* ]]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "true" ]
}

@test "already_in_state: reports 'was already', exits 0, does NOT rewrite" {
  _write_config true true
  before="$(_stat_fingerprint "$CONFIG")"
  run "$TOGGLE" rag on
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag.enabled was already true"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Flip (no explicit state)
# ---------------------------------------------------------------------------

@test "flip_true_to_false: 'distill' alone inverts the current value" {
  _write_config true true
  run "$TOGGLE" distill
  [ "$status" -eq 0 ]
  [[ "$output" == *"distill.enabled: true -> false"* ]]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "false" ]
}

@test "flip_false_to_true: 'rag' alone inverts the current value" {
  _write_config false true
  run "$TOGGLE" rag
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag.enabled: false -> true"* ]]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
}

# ---------------------------------------------------------------------------
# Aliases (AC8)
# ---------------------------------------------------------------------------

@test "alias_on_variants: on|true|1|yes all set to true" {
  local alias
  for alias in on true 1 yes; do
    _write_config false true
    run "$TOGGLE" rag "$alias"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
  done
}

@test "alias_off_variants: off|false|0|no all set to false" {
  local alias
  for alias in off false 0 no; do
    _write_config true true
    run "$TOGGLE" rag "$alias"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rag.enabled' "$CONFIG")" = "false" ]
  done
}

@test "alias_case_insensitive: 'OFF' / 'True' resolve the same as lowercase" {
  _write_config true true
  run "$TOGGLE" rag OFF
  [ "$status" -eq 0 ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "false" ]

  _write_config false true
  run "$TOGGLE" rag True
  [ "$status" -eq 0 ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
}

# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

@test "unknown_feature: foobar → stderr ERROR, exit 2, config unchanged" {
  _write_config true true
  before="$(_stat_fingerprint "$CONFIG")"
  run "$TOGGLE" foobar on
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"ERROR: unknown feature 'foobar'"* ]] || [[ "$output" == *"ERROR: unknown feature 'foobar'"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

@test "unknown_state: 'rag maybe' → stderr ERROR, exit 2, config unchanged" {
  _write_config true true
  before="$(_stat_fingerprint "$CONFIG")"
  run "$TOGGLE" rag maybe
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"ERROR: unknown state 'maybe'"* ]] || [[ "$output" == *"ERROR: unknown state 'maybe'"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

@test "too_many_args: three positional args → usage, exit 2" {
  _write_config true true
  run "$TOGGLE" rag on extra
  [ "$status" -eq 2 ]
}

@test "missing_config: no config file → stderr ERROR, exit 1, no file created" {
  [ ! -e "$CONFIG" ]
  run "$TOGGLE" rag on
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"ERROR: config not found"* ]] || [[ "$output" == *"ERROR: config not found"* ]]
  [[ "$stderr" == *"/obsidian-memory:setup"* ]] || [[ "$output" == *"/obsidian-memory:setup"* ]]
  [ ! -e "$CONFIG" ]
}

# ---------------------------------------------------------------------------
# Key preservation (T003)
# ---------------------------------------------------------------------------

@test "preserve_unrelated_keys: customFoo round-trips after a toggle" {
  _write_config_with_custom true true
  run "$TOGGLE" rag off
  [ "$status" -eq 0 ]
  [ "$(jq -r '.customFoo' "$CONFIG")" = "42" ]
  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "false" ]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "true" ]
}

@test "preserve_2space_indent: rewritten config still uses 2-space indent" {
  _write_config true true
  run "$TOGGLE" rag off
  [ "$status" -eq 0 ]
  # A 2-space-indented body has at least one "  \"" line.
  grep -q '^  "' "$CONFIG"
  # And the nested boolean is indented with 4 spaces, not 1 or a tab.
  grep -q '^    "enabled":' "$CONFIG"
}

@test "missing_feature_stanza: jq creates the stanza; other keys survive" {
  # Config has NO "distill" key at all.
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": {
    "enabled": true
  }
}
EOF
  run "$TOGGLE" distill on
  [ "$status" -eq 0 ]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "true" ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
}

@test "missing_feature_stanza_status: unset flag reports as true" {
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": {
    "enabled": true
  }
}
EOF
  before="$(_stat_fingerprint "$CONFIG")"
  run "$TOGGLE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"distill.enabled: true"* ]]
  after="$(_stat_fingerprint "$CONFIG")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Atomic-write invariant
# ---------------------------------------------------------------------------

# Replace `mv` on PATH with a stub that always fails. The script should detect
# the failure, exit 1, and leave the original config untouched byte-for-byte.
# The EXIT trap clears the .tmp.$$ droppings.
@test "atomic_write_mv_fails: original config untouched when mv fails" {
  _write_config_with_custom true true
  before_bytes="$(cksum < "$CONFIG")"

  local bindir="$BATS_TEST_TMPDIR/failbin"
  mkdir -p "$bindir"
  # Symlink every real executable into the stub bindir so bash, jq, cksum,
  # stat, grep, etc. still resolve.
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

  rm -f "$bindir/mv"
  cat > "$bindir/mv" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$bindir/mv"

  PATH="$bindir" run "$TOGGLE" rag off
  [ "$status" -eq 1 ]

  after_bytes="$(cksum < "$CONFIG")"
  [ "$before_bytes" = "$after_bytes" ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
  [ "$(jq -r '.customFoo' "$CONFIG")" = "42" ]

  # EXIT trap cleaned up any temp droppings.
  run bash -c "ls '$HOME/.claude/obsidian-memory/'*.tmp.* 2>/dev/null"
  [ "$status" -ne 0 ] || [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Shellcheck gate
# ---------------------------------------------------------------------------

@test "shellcheck_clean: scripts/vault-toggle.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$PLUGIN_ROOT/scripts/vault-toggle.sh"
  [ "$status" -eq 0 ]
}
