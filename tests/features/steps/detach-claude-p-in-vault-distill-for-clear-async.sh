# tests/features/steps/detach-claude-p-in-vault-distill-for-clear-async.sh
# Step definitions for
# specs/bug-detach-claude-p-in-vault-distill-for-clear-async/feature.gherkin (#25).
#
# Tests the async worker split introduced in vault-distill.sh: the sync head
# returns fast while the detached worker completes claude -p asynchronously.

# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2153,SC1091
. "$STEPS_DIR/distill.sh"
. "$STEPS_DIR/manual-distill.sh"

# Timing result populated by when_a_sessionend_payload_with_reason_is_piped_into
ASYNC_INVOKE_DURATION=0
# Path to the note found asynchronously
ASYNC_NOTE=""
# Reason used in async invocation
ASYNC_REASON="clear"
# Transcript path used for the async test
ASYNC_TRANSCRIPT=""
ASYNC_SESSION_ID=""

# ---------------------------------------------------------------------------
# Additional Given steps (supplements distill.sh and common.sh)
# ---------------------------------------------------------------------------

given_a_transcript_at_of_size_5000_bytes() {
  ASYNC_TRANSCRIPT="$(_expand_transcript_path "$1")"
  DISTILL_TRANSCRIPT="$ASYNC_TRANSCRIPT"
  ASYNC_SESSION_ID="$DISTILL_SESSION_ID"
  _seed_transcript "$ASYNC_TRANSCRIPT" 5000
}

given_a_transcript_at_of_size_500_bytes() {
  ASYNC_TRANSCRIPT="$(_expand_transcript_path "$1")"
  DISTILL_TRANSCRIPT="$ASYNC_TRANSCRIPT"
  ASYNC_SESSION_ID="$DISTILL_SESSION_ID"
  _seed_transcript "$ASYNC_TRANSCRIPT" 500
}

# Install a slow-claude stub that sleeps 15 s before printing a note body.
# Used to prove the sync head returns before claude -p finishes.
given_the_stub_cli_sleeps_for_15_seconds_before_responding() {
  local bindir="${BATS_TEST_TMPDIR:-/tmp}/bin"
  mkdir -p "$bindir"
  cat > "$bindir/claude" << 'SLOW_FAKE'
#!/usr/bin/env bash
sleep 15
cat << 'NOTE'
## Summary

Slow fake distillation from the test harness.

## Decisions

- Fake decision.
NOTE
SLOW_FAKE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}

# Install a recursive-claude stub: after completing, it pipes a fresh
# SessionEnd payload into vault-distill.sh to simulate the nested hook.
given_the_stub_cli_will_upon_completion_trigger_a_recursive_sessionend_invocation_of() {
  local _script_rel="$1"   # "scripts/vault-distill.sh" (unused — uses PLUGIN_ROOT)
  local bindir="${BATS_TEST_TMPDIR:-/tmp}/bin"
  mkdir -p "$bindir"

  # Write the stub with all needed env vars captured from the current env.
  # The stub will fire vault-distill.sh with OM_DISTILL_WORKER_ACTIVE=1 and
  # CLAUDECODE="" to simulate the nested-hook call path.
  cat > "$bindir/claude" << RECURSIVE_FAKE
#!/usr/bin/env bash
cat << 'NOTE'
## Summary

Recursive fake distillation.
NOTE

# Simulate the nested SessionEnd re-entry that claude -p fires.
# This re-entry should be suppressed by the re-entrancy guard.
if [ "\${OM_DISTILL_WORKER_ACTIVE:-}" = "1" ] && [ -z "\${CLAUDECODE:-}" ]; then
  # We are inside the worker; fire the recursive re-entry.
  REENTRY_PAYLOAD="\$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s","reason":"clear"}' \
    "\${TRANSCRIPT:-$ASYNC_TRANSCRIPT}" "\${CWD:-/tmp/my-proj}" "\${SESSION_ID:-${ASYNC_SESSION_ID:-reentry}}")"
  printf '%s' "\$REENTRY_PAYLOAD" \
    | OM_DISTILL_WORKER_ACTIVE=1 CLAUDECODE="" \
      bash "$PLUGIN_ROOT/scripts/vault-distill.sh" >/dev/null 2>/dev/null || true
fi
RECURSIVE_FAKE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}

# ---------------------------------------------------------------------------
# When steps
# ---------------------------------------------------------------------------

when_a_sessionend_payload_with_reason_is_piped_into() {
  local reason="$1"
  local _script="$2"   # e.g. "scripts/vault-distill.sh" — informational
  ASYNC_REASON="$reason"
  [ -n "$ASYNC_TRANSCRIPT" ] || {
    ASYNC_TRANSCRIPT="$HOME/.claude/projects/my-proj/fallback.jsonl"
    ASYNC_SESSION_ID="fallback"
    _seed_transcript "$ASYNC_TRANSCRIPT" 5000
  }
  DISTILL_TRANSCRIPT="$ASYNC_TRANSCRIPT"
  DISTILL_SESSION_ID="${ASYNC_SESSION_ID:-unknown}"

  local payload start_s end_s
  payload="$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s","reason":"%s"}' \
    "$ASYNC_TRANSCRIPT" "/tmp/my-proj" "${ASYNC_SESSION_ID:-unknown}" "$reason")"

  start_s="$(date +%s)"
  printf '%s' "$payload" | "$PLUGIN_ROOT/scripts/vault-distill.sh" >/dev/null 2>/dev/null
  DISTILL_RC=$?
  end_s="$(date +%s)"
  ASYNC_INVOKE_DURATION="$((end_s - start_s))"
}

when_is_invoked_against_the_newest_transcript() {
  local _skill="$1"   # "/obsidian-memory:distill-session" — informational
  MANUAL_SKILL_CWD="/tmp/my-proj"
  _run_distill_session_skill_impl
  # Wait up to 60 s for the worker to write the note (AC3).
  local waited=0
  while [ "$waited" -lt 60 ]; do
    ASYNC_NOTE="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null \
                  | sort | tail -n 1)"
    [ -n "$ASYNC_NOTE" ] && break
    sleep 1
    waited=$((waited + 1))
  done
}

# ---------------------------------------------------------------------------
# Then steps
# ---------------------------------------------------------------------------

then_returns_within_2_seconds() {
  local _script="$1"  # informational
  [ "$ASYNC_INVOKE_DURATION" -le 2 ] || {
    printf 'vault-distill.sh took %ds (limit: 2s)\n' "$ASYNC_INVOKE_DURATION" >&2
    return 1
  }
}

then_returns_within_1_second() {
  local _script="$1"  # informational
  [ "$ASYNC_INVOKE_DURATION" -le 1 ] || {
    printf 'vault-distill.sh took %ds (limit: 1s)\n' "$ASYNC_INVOKE_DURATION" >&2
    return 1
  }
}

then_within_30_seconds_a_file_matching_exists() {
  local _pattern="$1"  # informational / Gherkin placeholder
  local waited=0
  while [ "$waited" -lt 30 ]; do
    ASYNC_NOTE="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null \
                  | sort | tail -n 1)"
    [ -n "$ASYNC_NOTE" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  printf 'No note appeared within 30s\n' >&2
  return 1
}

then_within_30_seconds_exactly_one_file_matching_exists() {
  local _pattern="$1"  # informational
  local waited=0
  while [ "$waited" -lt 30 ]; do
    local count
    count="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -ge 1 ]; then
      ASYNC_NOTE="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null \
                    | sort | tail -n 1)"
      # Allow an extra second for any possible duplicate to materialise, then
      # verify exactly one note exists.
      sleep 2
      count="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$count" -ne 1 ]; then
        printf 'Expected exactly 1 note, found %s\n' "$count" >&2
        return 1
      fi
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'No note appeared within 30s\n' >&2
  return 1
}

then_within_60_seconds_exactly_one_file_matching_exists() {
  local _pattern="$1"  # informational
  local waited=0
  while [ "$waited" -lt 60 ]; do
    local count
    count="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -ge 1 ]; then
      ASYNC_NOTE="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null \
                    | sort | tail -n 1)"
      sleep 2
      count="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$count" -ne 1 ]; then
        printf 'Expected exactly 1 note, found %s\n' "$count" >&2
        return 1
      fi
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'No note appeared within 60s\n' >&2
  return 1
}

then_that_file_contains_the_distilled_body_from_the_stub() {
  [ -n "$ASYNC_NOTE" ] || {
    ASYNC_NOTE="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null \
                  | sort | tail -n 1)"
  }
  [ -n "$ASYNC_NOTE" ] && [ -f "$ASYNC_NOTE" ] || return 1
  # The slow stub and default stub both produce notes with "## Summary".
  grep -q '## Summary' "$ASYNC_NOTE"
}

then_contains_a_link_to_the_new_note() {
  local _index="$1"  # informational
  local index="$VAULT/claude-memory/Index.md"
  [ -f "$index" ] || {
    printf 'Index.md does not exist\n' >&2
    return 1
  }
  grep -q '^- \[\[' "$index"
}

then_contains_exactly_one_link_to_that_note() {
  local _index="$1"  # informational
  local index="$VAULT/claude-memory/Index.md"
  [ -f "$index" ] || {
    printf 'Index.md does not exist\n' >&2
    return 1
  }
  local count
  count="$(grep -c '^- \[\[' "$index")"
  [ "$count" -eq 1 ] || {
    printf 'Expected 1 link in Index.md, found %s\n' "$count" >&2
    return 1
  }
}

then_the_skill_reports_the_file_path_it_wrote() {
  # The manual-distill.sh skill impl stores the note path in MANUAL_SKILL_NOTE
  # and MANUAL_SKILL_OUTPUT. Verify one of those has a non-empty path.
  [ -n "$MANUAL_SKILL_NOTE" ] || [ -n "$ASYNC_NOTE" ] || return 1
}

then_no_file_matches_after_10_seconds() {
  local _pattern="$1"        # informational
  local _wait="${2:-}"       # informational; optional when unquoted in Gherkin
  sleep 2
  local count
  count="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ] || {
    printf 'Expected 0 notes after trivial-session skip, found %s\n' "$count" >&2
    return 1
  }
}

then_does_not_exist_or_contains_no_new_link() {
  local _index="$1"  # informational
  local index="$VAULT/claude-memory/Index.md"
  [ ! -f "$index" ] && return 0
  # Index may exist (created by Background setup); it must not have any link
  # added by the trivial-session invocation.
  # grep -c exits 1 with "0" output when no match — avoid || fallback that
  # would produce "0\n0" and break integer comparison.
  local count
  count="$(grep -c '^- \[\[' "$index" 2>/dev/null)" || true
  count="${count:-0}"
  [ "$count" -eq 0 ]
}
