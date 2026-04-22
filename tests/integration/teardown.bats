#!/usr/bin/env bats

# tests/integration/teardown.bats — end-to-end coverage of vault-teardown.sh.
#
# Every scenario runs under the bats scratch harness (tests/helpers/scratch)
# so $HOME is redirected to $BATS_TEST_TMPDIR/home and $VAULT is a disposable
# scratch vault. teardown() calls assert_sessions_untouched on every test
# except the purge-confirmed and idempotent-after-default cases — those
# legitimately delete the sessions subtree.
#
# Matches the test matrix in specs/feature-add-obsidian-memory-teardown-skill/
# design.md → Testing Strategy (17 rows).

setup() {
  load '../helpers/scratch'

  TEARDOWN="$PLUGIN_ROOT/scripts/vault-teardown.sh"
  export TEARDOWN

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG

  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"

  _install_safe_path
}

teardown() {
  if [ "${_SKIP_SESSIONS_ASSERT:-0}" != 1 ]; then
    assert_sessions_untouched
  fi
}

# Install a fresh PATH containing symlinks to every real executable plus a
# stub claude that logs invocations to $T_CLAUDE_LOG.
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

  T_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  export T_CLAUDE_LOG
  : > "$T_CLAUDE_LOG"

  _install_stub_claude succeed

  PATH="$bindir"
  export PATH
}

_install_stub_claude() {
  local mode="${1:-succeed}"
  local bindir="$BATS_TEST_TMPDIR/bin"
  local rc
  case "$mode" in
    succeed) rc=0 ;;
    fail)    rc=1 ;;
    *) return 1 ;;
  esac

  rm -f "$bindir/claude"
  cat > "$bindir/claude" <<CLAUDE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T_CLAUDE_LOG"
exit $rc
CLAUDE
  chmod +x "$bindir/claude"
}

_healthy_install() {
  local n="${1:-3}" i
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  mkdir -p "$VAULT/claude-memory/sessions/proj"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
  printf '# Claude Memory Index\n\n## Sessions\n' > "$VAULT/claude-memory/Index.md"
  for (( i = 1; i <= n; i++ )); do
    printf 'note %d\n' "$i" > "$VAULT/claude-memory/sessions/proj/note-$i.md"
  done
  snapshot_sessions
}

# --- AC1: default teardown --------------------------------------------------

@test "happy_default: default teardown removes config + symlink, preserves sessions" {
  _healthy_install 3
  run "$TEARDOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED"* ]]
  [[ "$output" == *"PRESERVED"* ]]
  [ ! -e "$CONFIG" ]
  [ ! -e "$VAULT/claude-memory/projects" ]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

# --- AC2: --purge variants --------------------------------------------------

@test "purge_yes: --purge with literal yes deletes sessions and Index.md" {
  _healthy_install 5
  _SKIP_SESSIONS_ASSERT=1
  run bash -c "printf 'yes\n' | '$TEARDOWN' --purge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Distilled notes deleted"* ]]
  [ ! -e "$CONFIG" ]
  [ ! -e "$VAULT/claude-memory/projects" ]
  [ ! -e "$VAULT/claude-memory/sessions" ]
  [ ! -e "$VAULT/claude-memory/Index.md" ]
}

@test "purge_y: --purge with 'y' cancels and preserves sessions" {
  _healthy_install 5
  run bash -c "printf 'y\n' | '$TEARDOWN' --purge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge cancelled"* ]]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

@test "purge_cap_YES: --purge with 'YES' cancels and preserves sessions" {
  _healthy_install 5
  run bash -c "printf 'YES\n' | '$TEARDOWN' --purge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge cancelled"* ]]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

@test "purge_empty: --purge with empty line cancels and preserves sessions" {
  _healthy_install 5
  run bash -c "printf '\n' | '$TEARDOWN' --purge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge cancelled"* ]]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

@test "purge_eof: --purge with EOF on stdin cancels and preserves sessions" {
  _healthy_install 5
  run bash -c "'$TEARDOWN' --purge </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge cancelled"* ]]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

# --- AC3: --unregister-mcp --------------------------------------------------

@test "unregister_mcp_ok: --unregister-mcp invokes claude mcp remove" {
  _healthy_install 3
  _install_stub_claude succeed
  : > "$T_CLAUDE_LOG"
  run "$TEARDOWN" --unregister-mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP"* ]]
  grep -qF "mcp remove obsidian -s user" "$T_CLAUDE_LOG"
  [ ! -e "$CONFIG" ]
  [ ! -e "$VAULT/claude-memory/projects" ]
}

@test "unregister_mcp_fail: non-zero claude exit is non-fatal" {
  _healthy_install 3
  _install_stub_claude fail
  : > "$T_CLAUDE_LOG"
  run "$TEARDOWN" --unregister-mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP"* ]]
  [ ! -e "$CONFIG" ]
  [ ! -e "$VAULT/claude-memory/projects" ]
}

# --- AC4: path-safety refusal -----------------------------------------------

@test "refuse_no_claude_memory: vault has no claude-memory dir → REFUSED, nothing deleted" {
  _healthy_install 3
  rm -rf "$VAULT/claude-memory"
  snapshot_sessions
  run "$TEARDOWN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"/obsidian-memory:doctor"* ]]
  [ -f "$CONFIG" ]
}

@test "refuse_projects_not_symlink: projects is a regular directory → REFUSED" {
  _healthy_install 3
  rm -f "$VAULT/claude-memory/projects"
  mkdir -p "$VAULT/claude-memory/projects/sub"
  printf 'marker\n' > "$VAULT/claude-memory/projects/keep.txt"
  run "$TEARDOWN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"/obsidian-memory:doctor"* ]]
  [ -f "$CONFIG" ]
  [ -d "$VAULT/claude-memory/projects" ]
}

@test "refuse_projects_wrong_target: projects symlink points elsewhere → REFUSED" {
  _healthy_install 3
  rm -f "$VAULT/claude-memory/projects"
  mkdir -p "$BATS_TEST_TMPDIR/unrelated"
  ln -s "$BATS_TEST_TMPDIR/unrelated" "$VAULT/claude-memory/projects"
  run "$TEARDOWN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"/obsidian-memory:doctor"* ]]
  [ -f "$CONFIG" ]
  [ -L "$VAULT/claude-memory/projects" ]
}

@test "refuse_vault_missing: configured vaultPath does not exist → REFUSED" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$BATS_TEST_TMPDIR/nope","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  snapshot_sessions
  run "$TEARDOWN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"/obsidian-memory:doctor"* ]]
  [ -f "$CONFIG" ]
}

# --- AC5: idempotency ------------------------------------------------------

@test "idempotent_no_config: no config at all → nothing to do, exit 0" {
  rm -rf "$HOME/.claude/obsidian-memory"
  snapshot_sessions
  run "$TEARDOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  [ ! -e "$CONFIG" ]
}

@test "idempotent_after_default: re-running after default teardown is a no-op" {
  _healthy_install 3
  _SKIP_SESSIONS_ASSERT=1
  run "$TEARDOWN"
  [ "$status" -eq 0 ]
  run "$TEARDOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
}

# --- AC6: --dry-run --------------------------------------------------------

@test "dry_run_healthy: --dry-run prints plan and touches nothing" {
  _healthy_install 4
  run "$TEARDOWN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
  [[ "$output" == *"WOULD PRESERVE"* ]]
  [ -f "$CONFIG" ]
  [ -L "$VAULT/claude-memory/projects" ]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

@test "dry_run_purge: --dry-run --purge lists sessions under WOULD REMOVE without prompting" {
  _healthy_install 4
  run bash -c "'$TEARDOWN' --dry-run --purge </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
  [[ "$output" == *"$VAULT/claude-memory/sessions"* ]]
  [[ "$output" != *"Type 'yes'"* ]]
  [ -f "$CONFIG" ]
  [ -L "$VAULT/claude-memory/projects" ]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

@test "dry_run_unregister: --dry-run --unregister-mcp does not invoke claude" {
  _healthy_install 3
  : > "$T_CLAUDE_LOG"
  run "$TEARDOWN" --dry-run --unregister-mcp
  [ "$status" -eq 0 ]
  [ ! -s "$T_CLAUDE_LOG" ]
  [ -f "$CONFIG" ]
}
