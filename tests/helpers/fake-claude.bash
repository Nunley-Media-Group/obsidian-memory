# tests/helpers/fake-claude.bash — deterministic "claude" CLI replacement.
#
# Used by distillation scenarios so scripts/vault-distill.sh does not spawn a
# real claude -p subprocess. Installs $BATS_TEST_TMPDIR/bin/claude ahead of
# the real binary on $PATH.
#
# Modes (selected via $FAKE_CLAUDE_MODE when the fake is invoked):
#   default   — emit a canned distillation note
#   empty     — emit nothing (exercises the fallback-stub code path)
#   env_echo  — echo $CLAUDECODE (verifies the parent clears it)

# shellcheck shell=bash

install_fake_claude() {
  local bindir="${BATS_TEST_TMPDIR:-/tmp}/bin"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<'FAKE'
#!/usr/bin/env bash
# Deterministic fake "claude" for obsidian-memory tests.
case "${FAKE_CLAUDE_MODE:-default}" in
  empty)
    exit 0
    ;;
  env_echo)
    printf '%s' "${CLAUDECODE-}"
    exit 0
    ;;
  default|*)
    cat <<'NOTE'
## Summary

Fake distillation from the test harness. No real model invocation occurred.

## Decisions

- Fake decision from the fake claude binary.

## Patterns & Gotchas

- Fake pattern for deterministic tests.

## Open Threads

- None.

## Tags

#project/scratch #test/fake
NOTE
    ;;
esac
FAKE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}
