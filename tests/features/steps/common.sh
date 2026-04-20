# tests/features/steps/common.sh — Background steps shared across every
# baseline feature. Sourced by tests/run-bdd.sh before any feature-specific
# step file.
#
# Every step function is idempotent and writes only under $BATS_TEST_TMPDIR.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153
# SC2154/SC2153 fire for VAULT/HOME/PLUGIN_ROOT/HELPERS_DIR — all set by
# tests/helpers/scratch.bash and tests/run-bdd.sh before common.sh is sourced.

# shellcheck disable=SC1091
. "$HELPERS_DIR/fake-claude.bash"

# _init_safe_path populates $BATS_TEST_TMPDIR/safebin with symlinks to every
# executable on the caller's PATH, then rewrites PATH to point only at that
# sanitized dir. Individual `given_is_not_on_path` steps delete specific
# symlinks to hide a binary without losing the rest (sed/tr/awk/...).
#
# A .initialized sentinel ensures the expensive PATH scan (500+ symlinks)
# runs at most once per scenario, even when multiple hide_binary calls fire
# in the same test.
_init_safe_path() {
  local bindir="$BATS_TEST_TMPDIR/safebin"
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
  : > "$bindir/.initialized"

  PATH="$bindir"
  export PATH
}

hide_binary() {
  _init_safe_path
  local bin="${1:-}"
  [ -n "$bin" ] || return 1
  rm -f "$BATS_TEST_TMPDIR/safebin/$bin"
  ! command -v "$bin" >/dev/null 2>&1
}

# Shared config helpers used by setup/rag/distill step files.
_config_path() {
  printf '%s' "$HOME/.claude/obsidian-memory/config.json"
}

_config_set_field() {
  # $1 = dotted field, $2 = literal JSON value (true/false/"string"/123)
  local field="$1" value="$2" cfg tmp
  cfg="$(_config_path)"
  [ -f "$cfg" ] || return 1
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  if jq --arg f "$field" --argjson v "$value" 'setpath($f | split("."); $v)' "$cfg" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp"
    return 1
  fi
}

_config_get_field() {
  local field="$1" cfg
  cfg="$(_config_path)"
  [ -f "$cfg" ] || return 1
  jq -r --arg f "$field" 'getpath($f | split("."))' "$cfg" 2>/dev/null
}

# cksum-based content hash of a single file.
_hash_file() {
  [ -f "$1" ] && cksum < "$1" 2>/dev/null || true
}

# Given a scratch HOME at "$BATS_TEST_TMPDIR/home"
given_a_scratch_home_at() {
  local expected="${1:-}"
  [ -n "$expected" ] || return 1
  [ "$HOME" = "$expected" ] || {
    printf 'expected HOME=%s, got %s\n' "$expected" "$HOME" >&2
    return 1
  }
  [ -d "$HOME" ]
}

# And a scratch Obsidian vault at "$BATS_TEST_TMPDIR/vault"
given_a_scratch_obsidian_vault_at() {
  local expected="${1:-}"
  [ -n "$expected" ] || return 1
  [ "$VAULT" = "$expected" ] || {
    printf 'expected VAULT=%s, got %s\n' "$expected" "$VAULT" >&2
    return 1
  }
  [ -d "$VAULT" ]
}

# And obsidian-memory is installed and setup against "$VAULT"
given_obsidian_memory_is_installed_and_setup_against() {
  local vault="${1:-}"
  [ -n "$vault" ] || return 1
  [ -d "$vault" ] || return 1

  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"

  cat > "$HOME/.claude/obsidian-memory/config.json" <<EOF
{"vaultPath":"$vault","rag":{"enabled":true},"distill":{"enabled":true}}
EOF

  mkdir -p "$vault/claude-memory/sessions"

  if [ ! -L "$vault/claude-memory/projects" ]; then
    ln -s "$HOME/.claude/projects" "$vault/claude-memory/projects"
  fi

  if [ ! -f "$vault/claude-memory/Index.md" ]; then
    {
      printf '# Claude Memory Index\n\n'
      printf 'Auto-generated session notes from the obsidian-memory plugin.\n\n'
      printf '## Sessions\n'
    } > "$vault/claude-memory/Index.md"
  fi
}

# And a stub "claude" CLI is on PATH returning a fixed distillation by default
given_a_stub_cli_is_on_path_returning_a_fixed_distillation_by_default() {
  install_fake_claude
  FAKE_CLAUDE_MODE="default"
  export FAKE_CLAUDE_MODE
}

# And the harness is installed at "$PLUGIN_ROOT/tests"
given_the_harness_is_installed_at() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  [ -x "$path/run-bdd.sh" ]
}
