#!/usr/bin/env bats

# tests/integration/doctor.bats — end-to-end coverage of vault-doctor.sh.
#
# Every scenario runs under the bats scratch harness (tests/helpers/scratch)
# so $HOME is redirected to $BATS_TEST_TMPDIR/home and $VAULT is a disposable
# scratch vault. teardown() asserts the real $HOME is byte-identical to its
# pre-test snapshot — proving the read-only invariant.

setup() {
  load '../helpers/scratch'

  DOCTOR="$PLUGIN_ROOT/scripts/vault-doctor.sh"
  export DOCTOR

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"

  _install_safe_path
}

teardown() {
  assert_home_untouched
}

# Install a fresh PATH containing symlinks to every real executable, plus a
# stub "claude" we fully control. Individual tests delete symlinks from this
# dir to simulate a missing binary.
_install_safe_path() {
  local bindir="$BATS_TEST_TMPDIR/bin"
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

  # Stub `claude` — real binary's mcp list may hit a live daemon.
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

  PATH="$bindir"
  export PATH
}

_hide() {
  rm -f "$BATS_TEST_TMPDIR/bin/$1"
}

_healthy_install() {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
}

# --- Happy path -------------------------------------------------------------

@test "healthy install: all probes report OK/INFO and exit 0" {
  _healthy_install

  run "$DOCTOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed."* ]]
  [[ "$output" != *"FAIL"* ]]
}

# --- Failure modes F1–F9 ----------------------------------------------------

@test "F1: config missing reports FAIL with setup hint" {
  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"config"* ]]
  [[ "$output" == *"/obsidian-memory:setup"* ]]
}

@test "F2: vaultPath missing from config reports FAIL with setup hint" {
  echo '{"rag":{"enabled":true},"distill":{"enabled":true}}' > "$CONFIG"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"vaultPath"* ]]
  [[ "$output" == *"/obsidian-memory:setup"* ]]
}

@test "F3: vaultPath points at non-existent directory reports FAIL with setup hint" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$BATS_TEST_TMPDIR/nope","rag":{"enabled":true},"distill":{"enabled":true}}
EOF

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"/obsidian-memory:setup"* ]]
}

@test "F4: jq missing reports FAIL with brew hint" {
  _healthy_install
  _hide jq

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"brew install jq"* ]]
}

@test "F5: claude missing reports FAIL with CLI install hint" {
  _healthy_install
  _hide claude

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"Claude Code CLI"* ]]
}

@test "F6: projects symlink broken reports FAIL with setup hint" {
  _healthy_install
  rm -f "$VAULT/claude-memory/projects"
  ln -s "$BATS_TEST_TMPDIR/does-not-exist" "$VAULT/claude-memory/projects"

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"projects"* ]]
  [[ "$output" == *"/obsidian-memory:setup"* ]]
}

@test "F7: sessions directory missing reports FAIL with setup hint" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  mkdir -p "$VAULT/claude-memory"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"sessions"* ]]
  [[ "$output" == *"/obsidian-memory:setup"* ]]
}

@test "F8: rag.enabled=false reports FAIL with toggle hint" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":false},"distill":{"enabled":true}}
EOF
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"rag.enabled"* ]]
  [[ "$output" == *"/obsidian-memory:toggle rag on"* ]]
}

@test "F9: distill.enabled=false reports FAIL with toggle hint" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":false}}
EOF
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  run "$DOCTOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"distill.enabled"* ]]
  [[ "$output" == *"/obsidian-memory:toggle distill on"* ]]
}

# --- Optional deps ----------------------------------------------------------

@test "ripgrep missing is INFO, not FAIL, and does not fail the run" {
  _healthy_install
  _hide rg

  run "$DOCTOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"* ]]
  [[ "$output" == *"ripgrep"* ]]
}

# --- JSON output ------------------------------------------------------------

@test "--json emits valid JSON with ok=true on healthy install" {
  _healthy_install

  run "$DOCTOR" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq empty
  [ "$(printf '%s' "$output" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.config.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.vault_path.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.jq.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.claude.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.sessions_dir.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.projects_symlink.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.rag_enabled.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.distill_enabled.status')" = "ok" ]
}

@test "--json emits ok=false with per-check hint on broken install" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$BATS_TEST_TMPDIR/nope","rag":{"enabled":true},"distill":{"enabled":true}}
EOF

  run "$DOCTOR" --json
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq empty
  [ "$(printf '%s' "$output" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.checks.vault_path.status')" = "fail" ]
  printf '%s' "$output" | jq -r '.checks.vault_path.hint' | grep -q '/obsidian-memory:setup'
}

# --- Read-only invariant ----------------------------------------------------

@test "doctor is read-only: scratch vault tree unchanged across healthy + broken invocations" {
  _healthy_install

  local before after
  before="$(find "$VAULT" "$HOME/.claude/obsidian-memory" -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null | LC_ALL=C sort)"

  run "$DOCTOR"
  [ "$status" -eq 0 ]
  run "$DOCTOR" --json
  [ "$status" -eq 0 ]

  rm -rf "$VAULT/claude-memory/sessions"
  run "$DOCTOR"
  [ "$status" -ne 0 ]

  mkdir -p "$VAULT/claude-memory/sessions"
  run "$DOCTOR"
  [ "$status" -eq 0 ]

  after="$(find "$VAULT" "$HOME/.claude/obsidian-memory" -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

# --- CLI contract -----------------------------------------------------------

@test "unknown argument exits 2 with usage on stderr" {
  run "$DOCTOR" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* || "$output" == *"usage:"* ]]
}

@test "--help exits 0 with usage" {
  run "$DOCTOR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* || "$output" == *"usage:"* ]]
}
