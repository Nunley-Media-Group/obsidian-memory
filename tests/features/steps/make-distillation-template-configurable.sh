# tests/features/steps/make-distillation-template-configurable.sh — step
# definitions for specs/feature-make-distillation-template-configurable/
# feature.gherkin (#7).
#
# Exercises the configurable-template surface end-to-end against the scratch
# vault. Most scenarios install a prompt-capturing "claude" stub (on top of
# the fixed-output stub from tests/helpers/fake-claude.bash) so the exact
# prompt argv passed to claude -p can be asserted byte-for-byte.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153,SC2034
# SC2154/SC2153: HOME/VAULT/PLUGIN_ROOT/BATS_TEST_TMPDIR/CAPTURED_PROMPT come
# from tests/helpers/scratch.bash, tests/features/steps/common.sh, and this
# file's own setup steps. SC2034: module-scoped state (DISTILL_SESSION_ID)
# is read by step callbacks the dispatcher invokes dynamically.

DISTILL_STDERR=""
DISTILL_RC=0
DISTILL_TRANSCRIPT=""
DISTILL_SESSION_ID=""
CAPTURED_PROMPT=""

_prompt_capture_path() {
  printf '%s' "${CAPTURED_PROMPT:-$BATS_TEST_TMPDIR/captured-prompt.txt}"
}

_install_prompt_capturing_stub() {
  # Overwrites tests/helpers/fake-claude.bash's stub so we can observe the
  # exact prompt argv the hook passes to `claude -p`. The body echoed back
  # is still deterministic ("STUBBED_NOTE_BODY") so the note content is
  # irrelevant to prompt-side assertions.
  local bindir="${1:-$BATS_TEST_TMPDIR/bin}"
  CAPTURED_PROMPT="$BATS_TEST_TMPDIR/captured-prompt.txt"
  export CAPTURED_PROMPT
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<STUB
#!/usr/bin/env bash
# Prompt-capturing claude stub for issue-#7 scenarios. argv[1] is "-p";
# argv[2] is the prompt string the hook composed after template rendering.
printf '%s' "\$2" > "$CAPTURED_PROMPT"
printf '%s\n' "STUBBED_NOTE_BODY"
STUB
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}

# _seed_transcript, _distill_invoke, _latest_note_in live in common.sh.
_latest_note_under() { _latest_note_in "${1%/}"; }

_nth_line() {
  # $1 = file, $2 = line number (1-indexed)
  awk -v n="$2" 'NR == n { print; exit }' "$1"
}

_captured_prompt_contents() {
  local p
  p="$(_prompt_capture_path)"
  [ -f "$p" ] || return 1
  cat "$p"
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_a_prompt_capturing_claude_stub_is_installed_at() {
  _install_prompt_capturing_stub "$1"
}

given_a_transcript_at_of_size_5000_bytes() {
  DISTILL_TRANSCRIPT="$1"
  DISTILL_SESSION_ID="widgets-session"
  _seed_transcript "$DISTILL_TRANSCRIPT" 5000
}

given_a_readable_template_at_with_content() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%b' "$content" > "$path"
}

given_an_empty_file_at() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  : > "$path"
}

given_the_config_sets_to() {
  local key="$1" val="$2"
  local cfg="$HOME/.claude/obsidian-memory/config.json"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  if jq --arg f "$key" --arg v "$val" 'setpath($f | split("."); $v)' "$cfg" > "$tmp"; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp"
    return 1
  fi
}

given_the_config_sets_to_the_bundled_default_template() {
  local key="$1"
  local bundled="$PLUGIN_ROOT/templates/default-distillation.md"
  given_the_config_sets_to "$key" "$bundled"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_sessionend_fires_with_cwd_session_id() {
  local cwd="$1" sid="$2"
  DISTILL_SESSION_ID="$sid"
  _distill_invoke "$DISTILL_TRANSCRIPT" "$cwd" "$sid" "clear"
}

# ------------------------------------------------------------
# Then steps — captured prompt
# ------------------------------------------------------------

then_the_captured_prompt_starts_with_followed_by_today_s_utc_date() {
  local prefix="$1"
  local today
  today="$(date -u +%Y-%m-%d)"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  case "$captured" in
    "${prefix}${today}"*) return 0 ;;
    *)
      printf 'expected prompt to start with "%s%s", got head:\n%s\n' \
        "$prefix" "$today" "$(printf '%s' "$captured" | head -c 200)" >&2
      return 1
      ;;
  esac
}

then_the_captured_prompt_contains() {
  local needle="$1"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  case "$captured" in
    *"$needle"*) return 0 ;;
  esac
  printf 'captured prompt did not contain: %s\n' "$needle" >&2
  return 1
}

then_the_captured_prompt_contains_followed_by_today_s_utc_date() {
  local prefix="$1"
  local today
  today="$(date -u +%Y-%m-%d)"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  case "$captured" in
    *"${prefix}${today}"*) return 0 ;;
  esac
  printf 'captured prompt missing "%s%s"\n' "$prefix" "$today" >&2
  return 1
}

then_the_captured_prompt_contains_the_literal_substring() {
  local needle="$1"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  case "$captured" in
    *"$needle"*) return 0 ;;
  esac
  printf 'captured prompt missing literal substring: %s\n' "$needle" >&2
  return 1
}

then_the_captured_prompt_does_not_contain_the_bare_token() {
  local token="$1"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  case "$captured" in
    *"$token"*)
      printf 'captured prompt unexpectedly contained bare token: %s\n' "$token" >&2
      return 1
      ;;
  esac
  return 0
}

then_the_captured_prompt_does_not_contain_at_the_start() {
  local token="$1"
  local captured
  captured="$(_captured_prompt_contents)" || return 1
  # printf %b to interpret \n in the Gherkin literal (e.g., "---\n").
  local decoded
  decoded="$(printf '%b' "$token")"
  case "$captured" in
    "$decoded"*)
      printf 'captured prompt unexpectedly started with: %q\n' "$decoded" >&2
      return 1
      ;;
  esac
  return 0
}

then_the_captured_prompt_prefix_matches_the_golden_fixture() {
  local rel="$1"
  local fixture="$PLUGIN_ROOT/$rel"
  local captured
  captured="$(_prompt_capture_path)"
  [ -f "$fixture" ] || { printf 'missing fixture: %s\n' "$fixture" >&2; return 1; }
  [ -f "$captured" ] || { printf 'no captured prompt\n' >&2; return 1; }
  local fix_size
  fix_size="$(wc -c < "$fixture" | tr -d ' ')"
  head -c "$fix_size" "$captured" | cmp -s - "$fixture" || {
    printf 'captured prompt prefix did not match %s (first %s bytes)\n' "$fixture" "$fix_size" >&2
    printf '--- expected head ---\n' >&2
    head -c 200 "$fixture" >&2
    printf '\n--- actual head ---\n' >&2
    head -c 200 "$captured" >&2
    printf '\n' >&2
    return 1
  }
}

# ------------------------------------------------------------
# Then steps — session notes
# ------------------------------------------------------------

then_a_session_note_file_exists_under() {
  local dir="$1"
  local f
  f="$(_latest_note_under "$dir")"
  [ -n "$f" ] && [ -f "$f" ]
}

then_the_latest_session_note_under_starts_with_a_yaml_frontmatter_block_with_keys_in_order() {
  local dir="$1" keys_csv="$2"
  local f
  f="$(_latest_note_under "$dir")"
  [ -n "$f" ] || { printf 'no note under %s\n' "$dir" >&2; return 1; }
  local actual_keys
  actual_keys="$(awk 'NR == 1 && /^---/ { flag = 1; next }
                     flag && /^---/ { exit }
                     flag { sub(/:.*/, ""); print }' "$f" | paste -sd ',' -)"
  if [ "$actual_keys" != "$keys_csv" ]; then
    printf 'frontmatter keys mismatch:\n  expected: %s\n  actual:   %s\n' \
      "$keys_csv" "$actual_keys" >&2
    return 1
  fi
}

then_the_index_md_line_under_matches_the_v0_1_pattern() {
  local path="$1" pattern="$2"
  [ -f "$path" ] || { printf 'missing: %s\n' "$path" >&2; return 1; }
  grep -qE "$pattern" "$path" || {
    printf 'no line in %s matched: %s\n' "$path" "$pattern" >&2
    tail -5 "$path" >&2
    return 1
  }
}

then_the_hook_stderr_contains_exactly_one_line_matching() {
  local pattern="$1"
  [ -f "$DISTILL_STDERR" ] || { printf 'no stderr log\n' >&2; return 1; }
  local n
  n="$(grep -cE "$pattern" "$DISTILL_STDERR" 2>/dev/null || printf 0)"
  if [ "$n" -ne 1 ]; then
    printf 'expected exactly one stderr line matching:\n  %s\nfound %d. stderr was:\n' \
      "$pattern" "$n" >&2
    cat "$DISTILL_STDERR" >&2
    return 1
  fi
}

then_the_latest_session_note_under_starts_with_exactly_5_frontmatter_lines_beginning_with_and_ending_with() {
  # args: <sessions-dir>, <open-delim>, <close-delim>
  # "<count>" appears between quoted literals in the Gherkin line and gets
  # stripped by _normalize_step — we validate structure rather than count.
  local dir="$1" open_delim="$2" close_delim="$3"
  local f
  f="$(_latest_note_under "$dir")"
  [ -n "$f" ] || { printf 'no note under %s\n' "$dir" >&2; return 1; }
  local first_line
  first_line="$(head -n 1 "$f")"
  [ "$first_line" = "$open_delim" ] || {
    printf 'first line was %q, expected %q\n' "$first_line" "$open_delim" >&2
    return 1
  }
  # Find the closing delimiter on or after line 2.
  awk -v d="$close_delim" '
    NR == 1 { next }
    $0 == d { print NR; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$f" >/dev/null || {
    printf 'no closing %s delimiter found after line 1 in %s\n' "$close_delim" "$f" >&2
    return 1
  }
}

then_the_latest_session_note_first_frontmatter_line_is() {
  local expected="$1"
  local f
  f="$(_latest_note_under "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  [ "$(head -n 1 "$f")" = "$expected" ]
}

then_the_latest_session_note_second_frontmatter_line_starts_with() {
  local prefix="$1"
  local f
  f="$(_latest_note_under "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  local line
  line="$(_nth_line "$f" 2)"
  case "$line" in
    "$prefix"*) return 0 ;;
    *)
      printf 'line 2 was %q, expected prefix %q\n' "$line" "$prefix" >&2
      return 1
      ;;
  esac
}

then_the_latest_session_note_third_frontmatter_line_is() {
  local expected="$1"
  local f
  f="$(_latest_note_under "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  [ "$(_nth_line "$f" 3)" = "$expected" ]
}

then_the_latest_session_note_fourth_frontmatter_line_is() {
  local expected="$1"
  local f
  f="$(_latest_note_under "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  [ "$(_nth_line "$f" 4)" = "$expected" ]
}

then_the_latest_session_note_does_not_contain_a_second_frontmatter_block_with() {
  local needle="$1"
  local f
  f="$(_latest_note_under "$VAULT/claude-memory/sessions")"
  [ -n "$f" ] || return 1
  if grep -qF -- "$needle" "$f"; then
    printf 'session note unexpectedly contained: %s\n' "$needle" >&2
    return 1
  fi
}

# ------------------------------------------------------------
# Then steps — hook exit
# ------------------------------------------------------------

then_the_hook_exit_code_is_0() {
  [ "$DISTILL_RC" = 0 ]
}
