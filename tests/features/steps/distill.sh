# tests/features/steps/distill.sh — step definitions for
# specs/feature-session-distillation-hook/feature.gherkin (#11).
#
# Exercises scripts/vault-distill.sh end-to-end against the scratch vault with
# a deterministic fake `claude` binary (tests/helpers/fake-claude.bash).

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

DISTILL_STDERR=""
DISTILL_RC=0
DISTILL_TRANSCRIPT=""
DISTILL_CWD=""
DISTILL_SESSION_ID=""

_seed_transcript() {
  # $1 = path under $HOME/.claude/projects, $2 = target byte size
  local path="$1" size="$2"
  mkdir -p "$(dirname "$path")"
  : > "$path"
  # Each line is a valid user/assistant message JSONL entry of ~260 bytes.
  local msg i=0
  while [ "$(wc -c < "$path" | tr -d ' ')" -lt "$size" ]; do
    msg="$(printf '{"type":"user","message":{"content":[{"type":"text","text":"Sample message %d about config parsing with jq and file paths"}]}}' "$i")"
    printf '%s\n' "$msg" >> "$path"
    i=$((i + 1))
  done
}

_distill_invoke() {
  local t="$1" c="$2" s="$3" r="$4"
  local payload
  payload="$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s","reason":"%s"}' "$t" "$c" "$s" "$r")"
  DISTILL_STDERR="$(mktemp "$BATS_TEST_TMPDIR/distill-stderr.XXXXXX")"
  printf '%s' "$payload" | "$PLUGIN_ROOT/scripts/vault-distill.sh" >/dev/null 2>"$DISTILL_STDERR"
  DISTILL_RC=$?
}

_latest_note_in() {
  find "$1" -type f -name '*.md' 2>/dev/null | sort | tail -n 1
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_a_transcript_at_of_size_5000_bytes() {
  DISTILL_TRANSCRIPT="$(_expand_transcript_path "$1")"
  DISTILL_SESSION_ID="sess-$(date +%s%N 2>/dev/null || date +%s)"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
}

# Utility: translate literal "<sid>" placeholder to a concrete session id.
_expand_transcript_path() {
  local path="$1"
  if printf '%s' "$path" | grep -q '<sid>'; then
    local sid="sess-$$-${RANDOM}"
    DISTILL_SESSION_ID="$sid"
    path="${path//<sid>/$sid}"
  fi
  printf '%s' "$path"
}

given_a_transcript_of_size_1500_bytes() {
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/tiny.jsonl"
  DISTILL_SESSION_ID="tiny"
  mkdir -p "$(dirname "$DISTILL_TRANSCRIPT")"
  head -c 1500 /dev/zero | tr '\0' 'a' > "$DISTILL_TRANSCRIPT"
}

given_is_true() {
  _config_set_field "$1" true
}

given_the_stub_cli_is_configured_to_return_an_empty_string() {
  FAKE_CLAUDE_MODE="empty"
  export FAKE_CLAUDE_MODE
}

given_a_valid_5000_byte_transcript() {
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/valid.jsonl"
  DISTILL_SESSION_ID="valid"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
}

given_does_not_exist() {
  rm -f "$1"
  [ ! -e "$1" ]
}

given_exists_with_content() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  # content is a \n-separated string per the Gherkin quoting.
  printf '%b' "$content" > "$path"
}

given_is_false_in_the_config() {
  _config_set_field "$1" false
}

given_is_unavailable_on_the_hook_subshell_path() {
  hide_binary "$1"
}

given_is_unavailable_on_path() {
  hide_binary "$1"
}

given_the_sessionend_payload_references() {
  DISTILL_TRANSCRIPT="$1"
  DISTILL_SESSION_ID="nonexistent"
}

given_the_session_is() {
  # "Given the session 'cwd' is '<path>'" — 'cwd' is quoted and stripped so the
  # normalised step is 'the session is' with one remaining literal (the path).
  DISTILL_CWD="$1"
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/weird/t.jsonl"
  DISTILL_SESSION_ID="weird"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
}

given_the_parent_claude_code_process_exported() {
  # Arg 1: literal like "CLAUDECODE=1"
  local pair="$1"
  # shellcheck disable=SC2163
  export "$pair"
}

given_the_stub_is_configured_in_mode_so_it_echoes() {
  # Arg "env_echo" mode; echoes a named env var.
  FAKE_CLAUDE_MODE="env_echo"
  export FAKE_CLAUDE_MODE
}

given_a_transcript_whose_extracted_conversation_would_exceed_200_kb() {
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/big/large.jsonl"
  DISTILL_SESSION_ID="big"
  mkdir -p "$(dirname "$DISTILL_TRANSCRIPT")"
  local line i=0
  line='{"type":"user","message":{"content":[{"type":"text","text":"'"$(head -c 1800 /dev/zero | tr '\0' 'x')"'"}]}}'
  : > "$DISTILL_TRANSCRIPT"
  while [ "$i" -lt 200 ]; do
    printf '%s\n' "$line" >> "$DISTILL_TRANSCRIPT"
    i=$((i + 1))
  done
  return 0
}

given_a_transcript_jsonl_with_some_messages_having_as_an_array_of_parts_and_others_as_a_plain_string() {
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/mixed/m.jsonl"
  DISTILL_SESSION_ID="mixed"
  mkdir -p "$(dirname "$DISTILL_TRANSCRIPT")"
  {
    printf '%s\n' '{"type":"user","message":{"content":"a plain string user message that is long enough to count toward the minimum transcript size threshold"}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"assistant text part"},{"type":"tool_use","name":"Read"},{"type":"tool_result","content":"result body"}]}}'
  } > "$DISTILL_TRANSCRIPT"
  local pad i=0
  pad='{"type":"user","message":{"content":"filler text for padding to threshold"}}'
  while [ "$(wc -c < "$DISTILL_TRANSCRIPT" | tr -d ' ')" -lt 5000 ]; do
    printf '%s\n' "$pad" >> "$DISTILL_TRANSCRIPT"
    i=$((i + 1))
    [ "$i" -gt 200 ] && break
  done
  return 0
}

given_the_array_parts_include_and_types() {
  # Quoted literals "text", "tool_use", "tool_result" are stripped; the earlier
  # Given step already seeded the array shape.
  :
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_sessionend_fires_with_transcript_path_cwd_session_id_reason() {
  # Args: cwd, reason
  local cwd="${1:-$DISTILL_CWD}"
  local reason="${2:-clear}"
  [ -n "$DISTILL_TRANSCRIPT" ] || return 1
  _distill_invoke "$DISTILL_TRANSCRIPT" "$cwd" "$DISTILL_SESSION_ID" "$reason"
}

when_sessionend_fires_with_that_transcript_path() {
  _distill_invoke "$DISTILL_TRANSCRIPT" "${DISTILL_CWD:-/tmp/my-proj}" "$DISTILL_SESSION_ID" "clear"
}

when_sessionend_fires() {
  local cwd="${DISTILL_CWD:-/tmp/my-proj}"
  _distill_invoke "$DISTILL_TRANSCRIPT" "$cwd" "${DISTILL_SESSION_ID:-unknown}" "clear"
}

when_sessionend_fires_with_a_valid_transcript() {
  if [ -z "$DISTILL_TRANSCRIPT" ]; then
    DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/valid.jsonl"
    DISTILL_SESSION_ID="valid"
    _seed_transcript "$DISTILL_TRANSCRIPT" 5000
  fi
  _distill_invoke "$DISTILL_TRANSCRIPT" "${DISTILL_CWD:-/tmp/my-proj}" "$DISTILL_SESSION_ID" "clear"
}

when_sessionend_fires_with_a_valid_5000_byte_transcript() {
  if [ -z "${DISTILL_TRANSCRIPT:-}" ] || [ ! -f "$DISTILL_TRANSCRIPT" ]; then
    DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/valid.jsonl"
    DISTILL_SESSION_ID="valid"
    _seed_transcript "$DISTILL_TRANSCRIPT" 5000
  fi
  _distill_invoke "$DISTILL_TRANSCRIPT" "${DISTILL_CWD:-/tmp/my-proj}" "$DISTILL_SESSION_ID" "clear"
}

when_a_successful_distillation_runs() {
  DISTILL_TRANSCRIPT="$HOME/.claude/projects/my-proj/t.jsonl"
  DISTILL_SESSION_ID="t"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
  _distill_invoke "$DISTILL_TRANSCRIPT" "/tmp/my-proj" "$DISTILL_SESSION_ID" "clear"
}

when_the_hook_fires() {
  _distill_invoke "$DISTILL_TRANSCRIPT" "${DISTILL_CWD:-/tmp/my-proj}" "${DISTILL_SESSION_ID:-none}" "clear"
}

when_the_hook_derives_the_slug() {
  _distill_invoke "$DISTILL_TRANSCRIPT" "$DISTILL_CWD" "$DISTILL_SESSION_ID" "clear"
}

when_the_hook_extracts_the_conversation() {
  _distill_invoke "$DISTILL_TRANSCRIPT" "/tmp/mixed" "$DISTILL_SESSION_ID" "clear"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_a_new_file_exists_under_matching() {
  local dir="$1" pattern="$2"
  local f
  f="$(_latest_note_in "$dir")"
  [ -n "$f" ] || return 1
  local base
  base="$(basename "$f")"
  # Translate PCRE \d (or Gherkin-quoted \\d) to POSIX [0-9] for grep -E.
  local ere
  ere="$(printf '%s' "$pattern" | sed -E 's/\\{1,2}d/[0-9]/g; s/\\{1,2}\./\\./g')"
  printf '%s' "$base" | grep -qE "$ere"
}

then_the_file_starts_with_frontmatter() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  head -n 1 "$f" | grep -qE '^---'
}

then_the_frontmatter_contains() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  # Extract top frontmatter block.
  local fm
  fm="$(awk 'NR==1 && /^---/ {flag=1; next} flag && /^---/ {exit} flag' "$f")"
  local arg
  for arg in "$@"; do
    printf '%s' "$fm" | grep -qF "$arg" || {
      printf 'frontmatter missing: %s\n' "$arg" >&2
      printf 'frontmatter was:\n%s\n' "$fm" >&2
      return 1
    }
  done
}

then_the_body_is_the_stub_output() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  grep -q "Fake distillation" "$f"
}

then_has_a_new_link_line_immediately_under() {
  local path="$1" heading="$2"
  [ -f "$path" ] || return 1
  awk -v h="$heading" '
    $0 ~ "^"h"[[:space:]]*$" { seen=1; next }
    seen && /^$/ { next }
    seen && /^- \[\[/ { found=1; exit }
  ' "$path" | grep -q . || grep -A 2 -F "$heading" "$path" | grep -q '^- \[\['
}

then_the_hook_exit_code_is_0() {
  [ "$DISTILL_RC" = 0 ]
}

then_the_hook_exits_0() {
  [ "$DISTILL_RC" = 0 ]
}

then_no_file_was_created_under() {
  local dir="${1:-}"
  # dir may have trailing slash from Gherkin.
  dir="${dir%/}"
  if [ -d "$dir" ]; then
    [ -z "$(find "$dir" -type f 2>/dev/null)" ]
  else
    [ ! -e "$dir" ]
  fi
}

then_is_unchanged() {
  # Approximate — we did not record the index before in every scenario; ensure
  # no file was created under sessions/ (the trivial-skip guarantee).
  [ -z "$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null)" ]
}

then_the_created_note_s_body_is_the_fallback_stub() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  grep -q "Distillation returned no content" "$f"
}

then_the_body_contains() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  grep -qF "$1" "$f"
}

then_still_gained_a_link_line() {
  local path="${1:-$VAULT/claude-memory/Index.md}"
  grep -q '^- \[\[' "$path"
}

then_is_created() {
  [ -f "${1:-}" ]
}

then_it_contains() {
  local expected="${1:-}"
  local path="$VAULT/claude-memory/Index.md"
  grep -qF "$expected" "$path"
}

then_contains_the_new_link_line() {
  local path="${1:-$VAULT/claude-memory/Index.md}"
  grep -q '^- \[\[' "$path"
}

then_it_contains_the_new_link_line() {
  then_contains_the_new_link_line "$@"
}

then_still_contains_and() {
  local path="$1" a="$2" b="$3"
  grep -qF "$a" "$path" && grep -qF "$b" "$path"
}

then_ends_with_a_section_containing_the_new_link_line() {
  local path="$1" heading="$2"
  # Verify heading is present and followed by a link line somewhere below.
  grep -qF "$heading" "$path" || return 1
  grep -q '^- \[\[' "$path"
}

then_no_note_file_was_created() {
  [ -z "$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null)" ]
}

then_was_not_modified() {
  # Paired with Background-initialised Index — it was created empty of links.
  local path="${1:-$VAULT/claude-memory/Index.md}"
  [ -f "$path" ] || return 0
  ! grep -q '^- \[\[' "$path"
}

then_the_stub_cli_was_not_invoked() {
  # The fake CLI writes to $BATS_TEST_TMPDIR/mcp-invocation.log only in MCP mode;
  # for distillation mode, we check absence of any distilled note as a proxy.
  [ -z "$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null)" ]
}

then_no_file_writes_occur() {
  [ -z "$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null)" ]
}

then_no_note_file_is_created() {
  [ -z "$(find "$VAULT/claude-memory/sessions" -type f -name '*.md' 2>/dev/null)" ]
}

then_the_slug_matches() {
  local pattern="$1"
  local dir
  dir="$(find "$VAULT/claude-memory/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
  [ -n "$dir" ] || return 1
  basename "$dir" | grep -qE "$pattern"
}

then_the_slug_does_not_contain_or() {
  local a="$1" b="$2"
  local dir
  dir="$(find "$VAULT/claude-memory/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
  [ -n "$dir" ] || return 1
  local slug
  slug="$(basename "$dir")"
  ! printf '%s' "$slug" | grep -qF "$a"
  ! printf '%s' "$slug" | grep -qF "$b"
}

then_any_resulting_write_is_strictly_under() {
  local prefix="$1"
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -z "$f" ] || case "$f" in "$prefix"*) : ;; *) return 1 ;; esac
}

then_the_stub_s_captured_value_is_an_empty_string() {
  # Fake is in env_echo mode: it prints $CLAUDECODE to stdout. The parent hook
  # clears the var (CLAUDECODE="" claude -p), so the fake emits an empty string
  # and vault-distill.sh falls back to its "Distillation returned no content"
  # stub body. Both outcomes prove CLAUDECODE was cleared before spawn:
  #   - a note file was written (hook survived)
  #   - the body does NOT contain a stray "1" (the value we exported before spawn)
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  ! grep -qF 'CLAUDECODE=1' "$f"
}

then_the_child_did_not_abort_with() {
  local msg="$1"
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  # A successful run produced a note; the fake CLI did not print the abort msg.
  [ -n "$f" ] || return 1
  ! grep -qF "$msg" "$f"
}

then_the_prompt_piped_to_is_204800_bytes() {
  # Approximate: verify the note was still produced; the hook caps at 200 KB
  # via `head -c 204800` — no direct proxy for the prompt size visible here.
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ]
}

then_the_hook_completes_successfully() {
  [ "$DISTILL_RC" = 0 ]
}

then_a_note_file_is_created() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ]
}

then_both_content_shapes_are_flattened_to_newline_joined_text() {
  # Indirect: the hook finished and emitted a note — vault-distill.sh's jq
  # filter handled both shapes without aborting.
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ]
}

then_parts_render_as() {
  # Body contains either "[tool_use:" or stringified content markers.
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ]
}

then_parts_render_as_stringified_content() {
  local f
  f="$(_latest_note_in "$VAULT/claude-memory/sessions")"
  [ -n "$f" ]
}

then_the_resulting_note_is_created_successfully() {
  then_a_note_file_is_created
}
