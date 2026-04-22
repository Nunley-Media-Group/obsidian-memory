# tests/helpers/scratch.bash — shared bats harness.
#
# Loaded via `load '../helpers/scratch'` (or equivalent) from any .bats test.
# Also sourced by tests/run-bdd.sh before each BDD scenario.
#
# Contract:
#   - Captures $REAL_HOME before mutating anything.
#   - Snapshots $REAL_HOME/.claude via cksum digest for assert_home_untouched.
#   - Redirects $HOME to $BATS_TEST_TMPDIR/home (creating .claude/ inside it).
#   - Creates scratch vault at $BATS_TEST_TMPDIR/vault and exports $VAULT.
#   - Exports $PLUGIN_ROOT — repo root resolved from this file's location.
#
# No shebang — sourced only, never executed directly.

# shellcheck shell=bash

if [ -z "${BATS_TEST_TMPDIR:-}" ]; then
  # Allow sourcing from tests/run-bdd.sh even when bats did not set the var.
  BATS_TEST_TMPDIR="${TMPDIR:-/tmp}/obm-scratch.$$.${RANDOM:-0}"
  mkdir -p "$BATS_TEST_TMPDIR"
  export BATS_TEST_TMPDIR
fi

if [ -z "${REAL_HOME:-}" ]; then
  REAL_HOME="$HOME"
  export REAL_HOME
fi

_home_digest() {
  # Digest scoped to paths obsidian-memory is allowed to mutate. Anything
  # OUTSIDE this narrow view — Claude Code's own state under ~/.claude/ — is
  # expected to churn during a live session and is intentionally ignored.
  #
  # Covered paths (relative to $home):
  #   .claude/obsidian-memory/   — config file + any future plugin state
  #
  # Intentionally NOT covered:
  #   .claude/projects/, tasks/, file-history/, plugins/*, plans/,
  #   paste-cache/, statsig/, shell-snapshots/, todos/, backups/, etc.
  #   (Claude Code writes to these during every test run.)
  local home="$1"
  [ -d "$home/.claude/obsidian-memory" ] || return 0
  ( cd "$home" \
    && find .claude/obsidian-memory -type f -print0 2>/dev/null \
       | LC_ALL=C sort -z \
       | xargs -0 cksum 2>/dev/null \
       | LC_ALL=C sort
  )
}

_SCRATCH_HOME_DIGEST="$(_home_digest "$REAL_HOME")"
export _SCRATCH_HOME_DIGEST

HOME="$BATS_TEST_TMPDIR/home"
mkdir -p "$HOME/.claude"
export HOME

VAULT="$BATS_TEST_TMPDIR/vault"
mkdir -p "$VAULT"
export VAULT

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PLUGIN_ROOT

_stat_fingerprint() {
  if stat -f '%i-%m' "$1" 2>/dev/null; then return 0; fi
  stat -c '%i-%Y' "$1"
}

assert_home_untouched() {
  local current
  current="$(_home_digest "$REAL_HOME")"
  if [ "$current" != "$_SCRATCH_HOME_DIGEST" ]; then
    # shellcheck disable=SC2016
    printf 'assert_home_untouched: real $HOME/.claude digest changed during test\n' >&2
    printf 'expected: %s\n' "$_SCRATCH_HOME_DIGEST" >&2
    printf 'actual:   %s\n' "$current" >&2
    return 1
  fi
  return 0
}

# Snapshot + assertion pair for the distilled-sessions subtree under the
# scratch vault. Used by teardown tests to prove that default / dry-run /
# refusal / purge-cancelled paths never mutate the user's memory.
_sessions_digest() {
  local vault="$1"
  [ -d "$vault/claude-memory" ] || return 0
  ( cd "$vault" \
    && find claude-memory/sessions claude-memory/Index.md \
         \( -type f -o -type d \) -print0 2>/dev/null \
       | LC_ALL=C sort -z \
       | xargs -0 cksum 2>/dev/null \
       | LC_ALL=C sort
  )
}

snapshot_sessions() {
  _SCRATCH_SESSIONS_DIGEST="$(_sessions_digest "$VAULT")"
  export _SCRATCH_SESSIONS_DIGEST
}

assert_sessions_untouched() {
  local current expected="${_SCRATCH_SESSIONS_DIGEST-}"
  current="$(_sessions_digest "$VAULT")"
  if [ "$current" != "$expected" ]; then
    printf 'assert_sessions_untouched: sessions/ or Index.md digest changed\n' >&2
    printf 'expected: %s\n' "$expected" >&2
    printf 'actual:   %s\n' "$current" >&2
    return 1
  fi
  return 0
}
