# tests/features/steps/manual-distill.sh — step definitions for
# specs/feature-manual-distill-skill/feature.gherkin (#12).
#
# Reuses distill.sh's hook helpers by sourcing it. Adds skill-level step
# definitions that reproduce the /obsidian-memory:distill-session workflow
# documented in skills/distill-session/SKILL.md.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153,SC1091
. "$STEPS_DIR/distill.sh"

MANUAL_SKILL_OUTPUT=""
MANUAL_SKILL_ERROR=""
MANUAL_SKILL_RC=0
MANUAL_SKILL_NOTE=""
MANUAL_SKILL_PAYLOAD=""
MANUAL_SKILL_USED_TRANSCRIPT=""
MANUAL_SKILL_CWD=""

_run_distill_session_skill_impl() {
  MANUAL_SKILL_OUTPUT=""
  MANUAL_SKILL_ERROR=""
  MANUAL_SKILL_NOTE=""
  MANUAL_SKILL_RC=0

  if ! command -v jq >/dev/null 2>&1; then
    MANUAL_SKILL_ERROR="missing jq dependency"
    MANUAL_SKILL_RC=1
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    MANUAL_SKILL_ERROR="missing claude dependency"
    MANUAL_SKILL_RC=1
    return 0
  fi

  local newest
  newest="$(find "$HOME/.claude/projects" -type f -name '*.jsonl' -print0 2>/dev/null \
             | xargs -0 ls -1t 2>/dev/null \
             | head -n 1)"
  if [ -z "$newest" ]; then
    MANUAL_SKILL_ERROR="no Claude Code transcripts found"
    MANUAL_SKILL_RC=1
    return 0
  fi

  MANUAL_SKILL_USED_TRANSCRIPT="$newest"
  local session_id cwd
  session_id="$(basename "$newest" .jsonl)"
  cwd="${MANUAL_SKILL_CWD:-$(pwd)}"

  MANUAL_SKILL_PAYLOAD="$(jq -n \
    --arg t "$newest" \
    --arg c "$cwd" \
    --arg s "$session_id" \
    --arg r "manual" \
    '{transcript_path:$t, cwd:$c, session_id:$s, reason:$r}' 2>/dev/null)"

  printf '%s' "$MANUAL_SKILL_PAYLOAD" \
    | "$PLUGIN_ROOT/scripts/vault-distill.sh" >/dev/null 2>&1
  MANUAL_SKILL_RC=$?

  local latest
  latest="$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' -print0 2>/dev/null \
             | xargs -0 ls -1t 2>/dev/null \
             | head -n 1)"
  MANUAL_SKILL_NOTE="$latest"
  MANUAL_SKILL_OUTPUT="note: ${MANUAL_SKILL_NOTE:-<none>}"
}

# Make setup.sh's _dispatch_command find the distill-session implementation.
# (setup.sh's when_the_user_runs delegates here for /obsidian-memory:distill-session.)

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_the_user_s_current_working_directory_is() {
  MANUAL_SKILL_CWD="$1"
  # Seed a transcript whenever a CWD is declared so the skill has work to do.
  if [ -z "${DISTILL_TRANSCRIPT:-}" ]; then
    DISTILL_TRANSCRIPT="$HOME/.claude/projects/cwd-session/t.jsonl"
    # shellcheck disable=SC2034
    DISTILL_SESSION_ID="cwd-session"
    _seed_transcript "$DISTILL_TRANSCRIPT" 5000
  fi
}

given_contains_no_files() {
  local dir="$1"
  # Second quoted literal "*.jsonl" describes the missing glob; nothing to do
  # beyond ensuring the dir is empty of transcripts.
  [ -d "$dir" ] || mkdir -p "$dir"
  find "$dir" -type f -name '*.jsonl' -delete 2>/dev/null || true
}

given_a_previous_manual_distillation_produced() {
  # Arg like "sessions/my-proj/2026-04-19-143022.md"
  local rel="$1"
  local path="$VAULT/claude-memory/$rel"
  mkdir -p "$(dirname "$path")"
  {
    printf -- '---\n'
    printf 'date: 2026-04-19\n'
    printf 'time: 14:30:22\n'
    printf 'session_id: prev\n'
    printf 'project: my-proj\n'
    printf 'cwd: /tmp/my-proj\n'
    printf 'end_reason: manual\n'
    printf 'source: claude-code\n'
    printf -- '---\n\n'
    printf '## Summary\n\nEarlier distillation.\n'
  } > "$path"

  # Update Index.md with a link to this note so re-running records the second.
  local index="$VAULT/claude-memory/Index.md"
  [ -f "$index" ] || {
    printf '# Claude Memory Index\n\n## Sessions\n\n' > "$index"
  }
  printf -- '- [[%s]] — my-proj (2026-04-19 14:30:22 UTC)\n' "$rel" >> "$index"

  MANUAL_SKILL_PREV_NOTE="$path"
  MANUAL_SKILL_PREV_CKSUM="$(cksum < "$path")"

  # Seed a transcript so the next skill run has something to distill.
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/next.jsonl"
  # shellcheck disable=SC2034
  DISTILL_SESSION_ID="next"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
  MANUAL_SKILL_CWD="/tmp/my-proj"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_the_user_runs() {
  # The quoted literal is the command; for distill-session it's parameterless.
  _run_distill_session_skill_impl
}

when_the_user_runs_again_2_seconds_later() {
  # Arg: "/obsidian-memory:distill-session". Sleep briefly so the timestamp
  # in the output filename (YYYY-MM-DD-HHMMSS) differs from the previous run.
  sleep 1
  _run_distill_session_skill_impl
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_skill_identifies_the_newest_under_as() {
  # Args: ".jsonl", "$HOME/.claude/projects/", "$TRANSCRIPT"
  local prefix="$2"
  [ -n "$MANUAL_SKILL_USED_TRANSCRIPT" ] || return 1
  case "$MANUAL_SKILL_USED_TRANSCRIPT" in
    "$prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

then_the_skill_pipes_a_payload_with_equal_to_into() {
  # Args: "reason", "manual", "vault-distill.sh"
  local field="$1" value="$2"
  [ -n "$MANUAL_SKILL_PAYLOAD" ] || return 1
  printf '%s' "$MANUAL_SKILL_PAYLOAD" | jq -e --arg f "$field" --arg v "$value" 'getpath($f | split(".")) == $v' >/dev/null
}

then_the_note_s_frontmatter_field_is() {
  local field="$1" value="$2"
  [ -n "$MANUAL_SKILL_NOTE" ] || return 1
  local fm
  fm="$(awk 'NR==1 && /^---/ {flag=1; next} flag && /^---/ {exit} flag' "$MANUAL_SKILL_NOTE")"
  printf '%s' "$fm" | grep -qE "^${field}:[[:space:]]*${value}\$"
}

then_the_skill_prints_the_note_path() {
  [ -n "$MANUAL_SKILL_NOTE" ]
}

then_the_skill_reports() {
  local needle="$1"
  printf '%s' "$MANUAL_SKILL_ERROR $MANUAL_SKILL_OUTPUT" | grep -qF "$needle"
}

then_the_skill_stops_without_calling() {
  # "vault-distill.sh" was not reached — verified by absence of a new note.
  [ -z "$MANUAL_SKILL_NOTE" ]
}

then_no_new_file_was_created_under() {
  local dir="${1:-}"
  dir="${dir%/}"
  if [ -d "$dir" ]; then
    [ -z "$(find "$dir" -type f -name '*.md' 2>/dev/null)" ]
  else
    [ ! -e "$dir" ]
  fi
}

then_the_skill_reports_the_missing_dependency() {
  local dep="$1"
  printf '%s' "$MANUAL_SKILL_ERROR" | grep -qiF "missing $dep"
}

then_the_skill_stops_without_invoking() {
  # Same semantics as the "calling" variant.
  [ -z "$MANUAL_SKILL_NOTE" ]
}

then_a_new_file_exists() {
  # Arg: "sessions/my-proj/2026-04-19-143024.md" — relative path pattern.
  # Verify the skill produced a note distinct from the pre-existing one.
  [ -n "$MANUAL_SKILL_NOTE" ] || return 1
  [ -f "$MANUAL_SKILL_NOTE" ] || return 1
  # The new note must differ from the pre-existing one.
  [ "$MANUAL_SKILL_NOTE" != "${MANUAL_SKILL_PREV_NOTE:-}" ]
}

then_the_previous_file_is_unchanged() {
  [ -n "${MANUAL_SKILL_PREV_NOTE:-}" ] || return 0
  [ "$(cksum < "$MANUAL_SKILL_PREV_NOTE")" = "${MANUAL_SKILL_PREV_CKSUM:-}" ]
}

then_both_files_are_listed_under_in() {
  # Args: "## Sessions", "$VAULT/claude-memory/Index.md"
  local heading="$1" path="$2"
  grep -qF "$heading" "$path" || return 1
  local count
  count="$(grep -c '^- \[\[' "$path")"
  [ "$count" -ge 2 ]
}

then_the_payload_field_equals() {
  local field="$1" value="$2"
  [ -n "$MANUAL_SKILL_PAYLOAD" ] || return 1
  printf '%s' "$MANUAL_SKILL_PAYLOAD" | jq -e --arg f "$field" --arg v "$value" 'getpath($f | split(".")) == $v' >/dev/null
}

then_the_hook_writes_the_note_under() {
  local dir="$1"
  [ -n "$MANUAL_SKILL_NOTE" ] || return 1
  case "$MANUAL_SKILL_NOTE" in "$dir"*) return 0 ;; *) return 1 ;; esac
}

then_the_skill_reports_that_note_s_path() {
  [ -n "$MANUAL_SKILL_NOTE" ]
}

then_the_skill_reports_for_the_produced_note() {
  # Arg: "fallback stub" — detect by inspecting note body.
  local needle="$1"
  [ -n "$MANUAL_SKILL_NOTE" ] || return 1
  case "$needle" in
    *fallback*|*stub*)
      grep -q "Distillation returned no content" "$MANUAL_SKILL_NOTE"
      ;;
    *)
      grep -qF "$needle" "$MANUAL_SKILL_NOTE"
      ;;
  esac
}

then_still_prints_the_note_path() {
  [ -n "$MANUAL_SKILL_NOTE" ]
}

then_the_skill_itself_exits_successfully() {
  [ "$MANUAL_SKILL_RC" = 0 ]
}
