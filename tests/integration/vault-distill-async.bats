#!/usr/bin/env bats

# tests/integration/vault-distill-async.bats — regression tests for issue #25:
# vault-distill.sh must return quickly (sync head) while the detached async
# worker writes the note after the hook returns.
#
# Timing / cardinality assertions — semantics (frontmatter, slug, template)
# are already covered by the existing session-distillation-hook.bats.

setup() {
  load '../helpers/scratch'
  load '../helpers/fake-claude'

  HELPERS_DIR="$PLUGIN_ROOT/tests/helpers"
  STEPS_DIR="$PLUGIN_ROOT/tests/features/steps"
  export HELPERS_DIR STEPS_DIR

  # shellcheck disable=SC1091
  . "$STEPS_DIR/common.sh"
  # shellcheck disable=SC1091
  . "$STEPS_DIR/distill.sh"

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  SESSIONS="$VAULT/claude-memory/sessions"
  INDEX="$VAULT/claude-memory/Index.md"
  DISTILL="$PLUGIN_ROOT/scripts/vault-distill.sh"
  export CONFIG SESSIONS INDEX DISTILL

  given_obsidian_memory_is_installed_and_setup_against "$VAULT"
  install_fake_claude
  FAKE_CLAUDE_MODE="default"
  export FAKE_CLAUDE_MODE
}

teardown() { assert_home_untouched; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_count_notes() {
  find "$SESSIONS" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

_count_index_links() {
  [ -f "$INDEX" ] || { printf '0'; return 0; }
  grep -c '^- \[\[' "$INDEX" 2>/dev/null || printf '0'
}

_seed() {
  # $1 = session_id label → returns transcript path
  local sid="${1:-t}"
  local path="$HOME/.claude/projects/my-proj/${sid}.jsonl"
  mkdir -p "$(dirname "$path")"
  _seed_transcript "$path" 5000
  printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Case 1: sync head returns within 2 s even when claude takes 15 s
# ---------------------------------------------------------------------------

@test "AC1: vault-distill.sh returns within 2 s when claude is slow (15 s stub)" {
  local transcript
  transcript="$(_seed ac1)"

  # Install a slow claude stub (sleeps 15 s then emits a note).
  local bindir="$BATS_TEST_TMPDIR/slowbin"
  mkdir -p "$bindir"
  cat > "$bindir/claude" << 'SLOW'
#!/usr/bin/env bash
sleep 15
echo "## Summary"
echo ""
echo "Slow fake distillation."
SLOW
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH" export PATH

  local start end duration
  start="$(date +%s)"
  _distill_invoke "$transcript" "/tmp/my-proj" "ac1-session" "clear"
  end="$(date +%s)"
  duration=$((end - start))

  [ "$duration" -le 2 ] || {
    printf 'vault-distill.sh took %ds (limit: 2s)\n' "$duration" >&2
    return 1
  }

  # Note should appear asynchronously within 20 s.
  local note
  note="$(_latest_note_in "$SESSIONS")" || {
    printf 'No note appeared within 20s\n' >&2
    return 1
  }
  [ -n "$note" ]
}

# ---------------------------------------------------------------------------
# Case 2: exactly one note — no duplicate from recursive claude -p SessionEnd
# ---------------------------------------------------------------------------

@test "AC3/FR3: exactly one note written even when recursive SessionEnd re-fires" {
  local transcript
  transcript="$(_seed ac3)"

  # Install a recursive stub: after writing its body, it also fires
  # vault-distill.sh with OM_DISTILL_WORKER_ACTIVE=1 + CLAUDECODE="" to
  # simulate the claude -p subprocess's own SessionEnd hook.
  local bindir="$BATS_TEST_TMPDIR/recbin"
  mkdir -p "$bindir"
  # Capture needed paths now (the stub runs in a fresh env).
  local distill_path="$DISTILL"
  local t_path="$transcript"
  local vault_path="$VAULT"
  local home_path="$HOME"
  cat > "$bindir/claude" << RECURSIVE
#!/usr/bin/env bash
echo "## Summary"
echo ""
echo "Recursive fake distillation."

# Simulate recursive SessionEnd re-entry.
REENTRY="\$(printf '{"transcript_path":"%s","cwd":"/tmp/my-proj","session_id":"reentry","reason":"clear"}' \
  "$t_path")"
printf '%s' "\$REENTRY" | HOME="$home_path" VAULT="$vault_path" \
  OM_DISTILL_WORKER_ACTIVE=1 CLAUDECODE="" bash "$distill_path" >/dev/null 2>/dev/null || true
RECURSIVE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH" export PATH

  _distill_invoke "$transcript" "/tmp/my-proj" "ac3-session" "clear"

  # Poll up to 20 s for exactly one note.
  local waited=0
  while [ "$waited" -lt 20 ]; do
    local count
    count="$(_count_notes)"
    if [ "$count" -ge 1 ]; then
      # Allow a brief moment for any duplicate worker to race.
      sleep 1
      count="$(_count_notes)"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  local count
  count="$(_count_notes)"
  [ "$count" -eq 1 ] || {
    printf 'Expected exactly 1 note, found %s\n' "$count" >&2
    return 1
  }

  local links
  links="$(_count_index_links)"
  [ "$links" -eq 1 ] || {
    printf 'Expected 1 Index.md link, found %s\n' "$links" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Case 3: trivial session (< 2 KB) — no worker spawned, returns fast
# ---------------------------------------------------------------------------

@test "FR1/size-floor: trivial transcript (<2 KB) exits immediately, no note written" {
  local path="$HOME/.claude/projects/my-proj/tiny.jsonl"
  mkdir -p "$(dirname "$path")"
  head -c 500 /dev/zero 2>/dev/null | tr '\0' 'a' > "$path" \
    || dd if=/dev/zero bs=500 count=1 2>/dev/null | tr '\0' 'a' > "$path"

  local start end duration
  start="$(date +%s)"
  _distill_invoke "$path" "/tmp/my-proj" "tiny-session" "clear"
  end="$(date +%s)"
  duration=$((end - start))

  # Should return within 1 s (no worker spawned for trivial sessions).
  [ "$duration" -le 1 ] || {
    printf 'vault-distill.sh took %ds for trivial transcript (limit: 1s)\n' "$duration" >&2
    return 1
  }

  # No note must appear even after waiting.
  sleep 2
  local count
  count="$(_count_notes)"
  [ "$count" -eq 0 ] || {
    printf 'Expected 0 notes for trivial transcript, found %s\n' "$count" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Case 4: /exit-path regression — note appears, no duplication
# ---------------------------------------------------------------------------

@test "AC2: /exit-reason produces exactly one note (no regression)" {
  local transcript
  transcript="$(_seed ac2)"

  _distill_invoke "$transcript" "/tmp/my-proj" "ac2-session" "other"

  local note
  note="$(_latest_note_in "$SESSIONS")" || {
    printf 'No note appeared within 20s\n' >&2
    return 1
  }

  [ -n "$note" ] && [ -f "$note" ]

  # Allow a brief moment for any duplicate worker to race.
  sleep 1
  local count
  count="$(_count_notes)"
  [ "$count" -eq 1 ] || {
    printf 'Expected exactly 1 note for /exit path, found %s\n' "$count" >&2
    return 1
  }

  local links
  links="$(_count_index_links)"
  [ "$links" -eq 1 ] || {
    printf 'Expected 1 Index.md link for /exit path, found %s\n' "$links" >&2
    return 1
  }
}
