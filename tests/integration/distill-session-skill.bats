#!/usr/bin/env bats

# tests/integration/distill-session-skill.bats — end-to-end coverage of the
# /obsidian-memory:distill-session skill. Reuses _run_distill_session_skill_impl
# from tests/features/steps/manual-distill.sh so the BDD and bats surfaces
# share one implementation of the skill's v0.1.0 pipeline. Each @test exercises
# one acceptance criterion from specs/feature-manual-distill-skill/requirements.md,
# matching T006/T007 in specs/feature-manual-distill-skill/tasks.md.

# shellcheck disable=SC2034
# MANUAL_SKILL_CWD is read by _run_distill_session_skill_impl (sourced from
# tests/features/steps/manual-distill.sh); shellcheck can't see the cross-file use.

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
  # shellcheck disable=SC1091
  . "$STEPS_DIR/manual-distill.sh"

  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  SESSIONS="$VAULT/claude-memory/sessions"
  INDEX="$VAULT/claude-memory/Index.md"
  export CONFIG SESSIONS INDEX

  # Match the Background steps of feature-manual-distill-skill.gherkin: scratch
  # HOME + scratch vault + setup config + fake claude CLI on PATH.
  given_obsidian_memory_is_installed_and_setup_against "$VAULT"
  install_fake_claude
  FAKE_CLAUDE_MODE="default"
  export FAKE_CLAUDE_MODE
}

teardown() { assert_home_untouched; }

_seed_real_transcript() {
  # $1 = transcript path (absolute), $2 = session-id label (for derivation)
  local path="$1"
  mkdir -p "$(dirname "$path")"
  _seed_transcript "$path" 5000
}

_note_frontmatter() {
  # $1 = note path — prints the top `---`-delimited frontmatter block.
  awk 'NR==1 && /^---/ {flag=1; next} flag && /^---/ {exit} flag' "$1"
}

# --- AC1: happy path — manual distillation during an active session --------

@test "AC1: skill writes a dated note with end_reason=manual under the slug derived from CWD" {
  local transcript="$HOME/.claude/projects/my-proj/sid-ac1.jsonl"
  _seed_real_transcript "$transcript"

  MANUAL_SKILL_CWD="/tmp/my-proj"
  _run_distill_session_skill_impl

  [ "$MANUAL_SKILL_RC" = 0 ]
  [ -n "$MANUAL_SKILL_NOTE" ]
  [ -f "$MANUAL_SKILL_NOTE" ]

  # Note filename is YYYY-MM-DD-HHMMSS.md and lives under the expected slug.
  local base dir_name
  base="$(basename "$MANUAL_SKILL_NOTE")"
  dir_name="$(basename "$(dirname "$MANUAL_SKILL_NOTE")")"
  printf '%s' "$base" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.md$'
  [ "$dir_name" = "my-proj" ]

  local fm
  fm="$(_note_frontmatter "$MANUAL_SKILL_NOTE")"
  printf '%s' "$fm" | grep -qE '^end_reason:[[:space:]]*manual$'

  # Skill piped the synthetic SessionEnd payload through vault-distill.sh.
  printf '%s' "$MANUAL_SKILL_PAYLOAD" | jq -e '.reason == "manual"' >/dev/null
  printf '%s' "$MANUAL_SKILL_PAYLOAD" | jq -e --arg t "$transcript" '.transcript_path == $t' >/dev/null
}

# --- AC2: no transcripts exist — clean abort, no note written ---------------

@test "AC2: empty ~/.claude/projects reports 'no Claude Code transcripts found' and writes nothing" {
  find "$HOME/.claude/projects" -type f -name '*.jsonl' -delete 2>/dev/null || true

  _run_distill_session_skill_impl

  printf '%s' "$MANUAL_SKILL_ERROR" | grep -qi 'no Claude Code transcripts'
  [ -z "$MANUAL_SKILL_NOTE" ]
  [ -z "$(find "$SESSIONS" -type f -name '*.md' 2>/dev/null)" ]
}

# --- AC3: missing hard deps — jq, claude ------------------------------------

@test "AC3a: missing jq is reported and the hook is never invoked" {
  _seed_real_transcript "$HOME/.claude/projects/my-proj/sid-ac3a.jsonl"
  hide_binary jq

  _run_distill_session_skill_impl

  printf '%s' "$MANUAL_SKILL_ERROR" | grep -qi 'missing jq'
  [ -z "$(find "$SESSIONS" -type f -name '*.md' 2>/dev/null)" ]
}

@test "AC3b: missing claude is reported and the hook is never invoked" {
  _seed_real_transcript "$HOME/.claude/projects/my-proj/sid-ac3b.jsonl"
  hide_binary claude

  _run_distill_session_skill_impl

  printf '%s' "$MANUAL_SKILL_ERROR" | grep -qi 'missing claude'
  [ -z "$(find "$SESSIONS" -type f -name '*.md' 2>/dev/null)" ]
}

# --- AC4: re-running produces a strictly newer timestamped note ------------

@test "AC4: two invocations produce two distinct timestamped notes; previous note unchanged" {
  _seed_real_transcript "$HOME/.claude/projects/my-proj/sid-ac4.jsonl"
  MANUAL_SKILL_CWD="/tmp/my-proj"

  _run_distill_session_skill_impl
  local first="$MANUAL_SKILL_NOTE"
  [ -n "$first" ] && [ -f "$first" ]
  local first_hash
  first_hash="$(cksum < "$first")"

  sleep 1
  _run_distill_session_skill_impl
  local second="$MANUAL_SKILL_NOTE"

  [ -n "$second" ] && [ -f "$second" ]
  [ "$first" != "$second" ]
  [ "$(cksum < "$first")" = "$first_hash" ]

  # Both notes linked under ## Sessions in Index.md.
  [ "$(grep -c '^- \[\[' "$INDEX")" -ge 2 ]
}

# --- AC5: CWD drives the project slug (hook owns sanitization) --------------

@test "AC5: a weird CWD is funneled into the hook as-is and resolves to a sanitized slug" {
  _seed_real_transcript "$HOME/.claude/projects/weird/sid-ac5.jsonl"
  MANUAL_SKILL_CWD="/tmp/My Weird & Project"

  _run_distill_session_skill_impl

  [ "$MANUAL_SKILL_RC" = 0 ]
  printf '%s' "$MANUAL_SKILL_PAYLOAD" \
    | jq -e --arg c "/tmp/My Weird & Project" '.cwd == $c' >/dev/null

  local dir_name
  dir_name="$(basename "$(dirname "$MANUAL_SKILL_NOTE")")"
  # Hook collapses CWD basename to [a-z0-9-] — spaces and ampersand must not survive.
  printf '%s' "$dir_name" | grep -qE '^[a-z0-9-]+$'
}

# --- AC6: hook-level silent guards do not surface as skill errors -----------

@test "AC6: trivial-size transcript (hook skips) leaves the skill exiting 0 with no new note" {
  # < 2 KB — hook's trivial-session guard exits 0 without writing.
  local path="$HOME/.claude/projects/my-proj/tiny.jsonl"
  mkdir -p "$(dirname "$path")"
  head -c 500 /dev/zero | tr '\0' 'a' > "$path"

  _run_distill_session_skill_impl

  [ "$MANUAL_SKILL_RC" = 0 ]
  [ -z "$(find "$SESSIONS" -type f -name '*.md' 2>/dev/null)" ]
}

# --- Success metric: skill output parity with direct hook invocation --------

@test "Parity: skill-produced and hook-produced notes match except for end_reason + timestamp-derived fields" {
  local transcript="$HOME/.claude/projects/my-proj/sid-parity.jsonl"
  _seed_real_transcript "$transcript"
  MANUAL_SKILL_CWD="/tmp/my-proj"

  _run_distill_session_skill_impl
  local via_skill="$MANUAL_SKILL_NOTE"
  [ -n "$via_skill" ] && [ -f "$via_skill" ]

  # Give the timestamp a chance to advance so the direct-hook file is distinct.
  sleep 1

  # Direct hook invocation with the same transcript + CWD + session_id but
  # reason="clear" (the auto-fired SessionEnd shape).
  local session_id
  session_id="$(basename "$transcript" .jsonl)"
  _distill_invoke "$transcript" "/tmp/my-proj" "$session_id" "clear"
  [ "$DISTILL_RC" = 0 ]

  local via_hook
  via_hook="$(find "$SESSIONS/my-proj" -type f -name '*.md' -print0 \
              | xargs -0 ls -1t | head -n 1)"
  [ -n "$via_hook" ] && [ -f "$via_hook" ]
  [ "$via_hook" != "$via_skill" ]

  # Strip timestamp-derived frontmatter keys (date/time/end_reason) plus the
  # trailing transcript-path line in the fallback-stub body; everything else
  # must be byte-identical.
  _strip_variant_lines() {
    awk '/^date:/ || /^time:/ || /^end_reason:/ { next } { print }' "$1"
  }

  diff <(_strip_variant_lines "$via_skill") <(_strip_variant_lines "$via_hook")
}

# --- AC7: fallback stub detection when claude -p returns empty --------------

@test "AC7: empty claude output produces a fallback-stub note and the skill still reports its path" {
  _seed_real_transcript "$HOME/.claude/projects/my-proj/sid-ac7.jsonl"
  MANUAL_SKILL_CWD="/tmp/my-proj"

  FAKE_CLAUDE_MODE="empty"
  export FAKE_CLAUDE_MODE

  _run_distill_session_skill_impl

  [ "$MANUAL_SKILL_RC" = 0 ]
  [ -n "$MANUAL_SKILL_NOTE" ]
  [ -f "$MANUAL_SKILL_NOTE" ]

  # The stub marker is the skill's signal for "real distillation vs. fallback".
  grep -q 'Distillation returned no content' "$MANUAL_SKILL_NOTE"

  # Skill reports the note path in its terminal output.
  printf '%s' "$MANUAL_SKILL_OUTPUT" | grep -qF "$MANUAL_SKILL_NOTE"
}
