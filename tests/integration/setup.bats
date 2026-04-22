#!/usr/bin/env bats

# tests/integration/setup.bats — end-to-end coverage of /obsidian-memory:setup.
#
# Reuses _run_setup_skill from tests/features/steps/setup.sh — the deterministic
# shell reproduction of the skill's v0.1.0 behaviour — so the BDD and bats
# surfaces share one implementation of the skill flow. Each test exercises one
# acceptance criterion from specs/feature-vault-setup/requirements.md, matching
# T006 in specs/feature-vault-setup/tasks.md.

setup() {
  load '../helpers/scratch'

  HELPERS_DIR="$PLUGIN_ROOT/tests/helpers"
  export HELPERS_DIR

  # shellcheck disable=SC1091
  . "$PLUGIN_ROOT/tests/features/steps/common.sh"
  # shellcheck disable=SC1091
  . "$PLUGIN_ROOT/tests/features/steps/setup.sh"

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG
}

teardown() {
  assert_home_untouched
}

_assert_baseline_artefacts_present() {
  [ -f "$CONFIG" ]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -L "$VAULT/claude-memory/projects" ]
  [ "$(readlink "$VAULT/claude-memory/projects")" = "$HOME/.claude/projects" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
  grep -qF '# Claude Memory Index' "$VAULT/claude-memory/Index.md"
  grep -qF '## Sessions' "$VAULT/claude-memory/Index.md"
}

_artefact_digest() {
  # Semantic digest — config.json is normalised through `jq -cS` so whitespace
  # differences between the initial `printf` write and subsequent `jq` rewrites
  # do not count as drift. Idempotency at the user-visible level is key-set,
  # value, Index.md content, and symlink target — not byte-level JSON layout.
  {
    if [ -f "$CONFIG" ]; then
      jq -cS . "$CONFIG" 2>/dev/null || printf 'unparseable-config\n'
    else
      printf 'no-config\n'
    fi
    cksum < "$VAULT/claude-memory/Index.md" 2>/dev/null || printf 'no-index\n'
    readlink "$VAULT/claude-memory/projects" 2>/dev/null || printf 'no-symlink\n'
    if [ -d "$VAULT/claude-memory/sessions" ]; then
      printf 'sessions-dir-present\n'
    else
      printf 'no-sessions\n'
    fi
  }
}

# --- AC1: first-run setup produces all four artefacts ----------------------

@test "AC1: first-run setup produces config, sessions dir, projects symlink, and Index.md" {
  [ ! -e "$CONFIG" ]

  _run_setup_skill "$VAULT"

  _assert_baseline_artefacts_present
  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
  [ "$(jq -r '.rag.enabled' "$CONFIG")" = "true" ]
  [ "$(jq -r '.distill.enabled' "$CONFIG")" = "true" ]
}

# --- AC2 + success metric: re-running 5x produces zero drift ---------------

@test "AC2: re-running setup 5x produces zero drift in config, Index.md, and projects symlink" {
  _run_setup_skill "$VAULT"
  _assert_baseline_artefacts_present

  local baseline current i
  baseline="$(_artefact_digest)"

  for i in 1 2 3 4 5; do
    _run_setup_skill "$VAULT"
    current="$(_artefact_digest)"
    if [ "$current" != "$baseline" ]; then
      printf 'drift on re-run %d\nexpected: %s\nactual:   %s\n' "$i" "$baseline" "$current" >&2
      return 1
    fi
  done
}

# --- AC2: extra user keys in config.json survive re-run --------------------

@test "AC2: re-running preserves unrelated user keys in config.json" {
  _run_setup_skill "$VAULT"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq '.notes = {"enabled": true}' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"

  _run_setup_skill "$VAULT"

  [ "$(jq -r '.vaultPath' "$CONFIG")" = "$VAULT" ]
  [ "$(jq -r '.notes.enabled' "$CONFIG")" = "true" ]
}

# --- AC3: missing vault path aborts cleanly --------------------------------

@test "AC3: missing vault path aborts without creating config or vault dirs" {
  local missing="$BATS_TEST_TMPDIR/no-such-vault"
  [ ! -e "$missing" ]

  _run_setup_skill "$missing"

  [ ! -f "$CONFIG" ]
  [ ! -e "$missing" ]
  printf '%s' "$_SETUP_ERROR" | grep -qi 'does not exist'
}

# --- AC4: non-symlink projects entry is refused without deletion -----------

@test "AC4: non-symlink projects directory is refused and user data is preserved" {
  mkdir -p "$VAULT/claude-memory/projects"
  printf 'user content\n' > "$VAULT/claude-memory/projects/user-file.md"

  _run_setup_skill "$VAULT"

  [ -d "$VAULT/claude-memory/projects" ]
  [ ! -L "$VAULT/claude-memory/projects" ]
  [ -f "$VAULT/claude-memory/projects/user-file.md" ]
  [ "$(cat "$VAULT/claude-memory/projects/user-file.md")" = 'user content' ]
  printf '%s' "$_SETUP_OUTPUT" | grep -qi 'move or remove'

  [ -f "$CONFIG" ]
  [ -d "$VAULT/claude-memory/sessions" ]
  [ -f "$VAULT/claude-memory/Index.md" ]
}

# --- AC5: stale symlink is repointed atomically ----------------------------

@test "AC5: stale projects symlink is repointed to ~/.claude/projects without data loss" {
  mkdir -p "$VAULT/claude-memory" "$BATS_TEST_TMPDIR/stale-target"
  ln -s "$BATS_TEST_TMPDIR/stale-target" "$VAULT/claude-memory/projects"
  printf 'preserved\n' > "$BATS_TEST_TMPDIR/stale-target/keep.txt"

  _run_setup_skill "$VAULT"

  [ -L "$VAULT/claude-memory/projects" ]
  [ "$(readlink "$VAULT/claude-memory/projects")" = "$HOME/.claude/projects" ]
  [ -f "$BATS_TEST_TMPDIR/stale-target/keep.txt" ]
}

# --- AC8: missing deps do not fail setup -----------------------------------

@test "AC8: setup completes filesystem steps and reports missing jq and claude" {
  hide_binary jq
  hide_binary claude

  _run_setup_skill "$VAULT"

  _assert_baseline_artefacts_present
  [ -z "$_SETUP_ERROR" ]
  printf '%s' "$_SETUP_MISSING_DEPS" | grep -qw jq
  printf '%s' "$_SETUP_MISSING_DEPS" | grep -qw claude
}
