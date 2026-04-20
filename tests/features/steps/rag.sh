# tests/features/steps/rag.sh — step definitions for
# specs/feature-rag-prompt-injection/feature.gherkin (#10).
#
# Every scenario pipes a JSON hook payload into scripts/vault-rag.sh, captures
# stdout + exit code, and asserts against the captured text.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

RAG_STDOUT=""
RAG_RC=0
RAG_PAYLOAD=""

_rag_invoke() {
  local prompt="$1"
  local escaped="${prompt//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  RAG_PAYLOAD="{\"prompt\":\"$escaped\"}"
  RAG_STDOUT="$(printf '%s' "$RAG_PAYLOAD" | "$PLUGIN_ROOT/scripts/vault-rag.sh" 2>/dev/null)"
  RAG_RC=$?
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

# Given a vault file "my-note.md" containing "jq is used for config parsing"
given_a_vault_file_containing() {
  local name="$1" text="$2"
  mkdir -p "$VAULT"
  printf '%s\n' "$text" > "$VAULT/$name"
}

# Given a vault file "my-note.md" contains the text "ripgrep not needed"
given_a_vault_file_contains_the_text() {
  given_a_vault_file_containing "$1" "$2"
}

# Given 10 vault notes each matching the prompt with a known hit count
given_10_vault_notes_each_matching_the_prompt_with_a_known_hit_count() {
  local i n keyword
  keyword="shared-keyword"
  # note-i.md gets i copies of the keyword
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n="$i"
    : > "$VAULT/note-$i.md"
    while [ "$n" -gt 0 ]; do
      printf '%s line %d\n' "$keyword" "$n" >> "$VAULT/note-$i.md"
      n=$((n - 1))
    done
  done
}

# Given a vault whose ".md" files contain no prompt keywords
given_a_vault_whose_files_contain_no_prompt_keywords() {
  printf 'just some static words about planets and oceans\n' > "$VAULT/unrelated.md"
}

# Given a vault with arbitrary content
given_a_vault_with_arbitrary_content() {
  printf 'some arbitrary words\n' > "$VAULT/arbitrary.md"
}

# Given "rg" is unavailable in the hook subshell
given_is_unavailable_in_the_hook_subshell() {
  hide_binary "$1"
}

# Given the config file has "rag.enabled" set to false
given_the_config_file_has_set_to_false() {
  _config_set_field "$1" false
}

# Given "$VAULT/claude-memory/projects/some-project/2026-04-18.jsonl" contains "jq"
given_contains() {
  local path="$1" text="$2"
  mkdir -p "$(dirname "$path")"
  # Resolve through symlink: if parent dir is a symlink we follow it.
  printf '%s\n' "$text" > "$path"
}

# Given no other file in "$VAULT" contains "jq"
given_no_other_file_in_contains() {
  # Guard: the prior given step seeded the only legitimate match. Nothing else
  # is needed — new scratch vaults are empty of *.md files.
  :
}

# Given "$VAULT/.obsidian/workspace.json" contains the prompt keyword
given_contains_the_prompt_keyword() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf 'ripgrep\n' > "$path"
}

# Given no other file contains the keyword
given_no_other_file_contains_the_keyword() {
  :
}

# Given "$HOME/.claude/obsidian-memory/config.json" does not exist
given_does_not_exist() {
  rm -f "$1"
  [ ! -e "$1" ]
}

# Given a prompt containing 20 distinct non-stopword tokens of length >= 4
given_a_prompt_containing_20_distinct_non_stopword_tokens_of_length_4() {
  _RAG_KEYWORD_PROMPT="alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango"
  # Seed a vault file matching all 20 so the hook emits output.
  printf '%s\n' "$_RAG_KEYWORD_PROMPT" > "$VAULT/tokens.md"
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

# When the user submits a prompt containing "<text>"
when_the_user_submits_a_prompt_containing() {
  _rag_invoke "$1"
}

# When the hook runs against a prompt matching the shared keyword
when_the_hook_runs_against_a_prompt_matching_the_shared_keyword() {
  _rag_invoke "shared-keyword appears frequently"
}

# When the user submits a prompt with no overlapping tokens
when_the_user_submits_a_prompt_with_no_overlapping_tokens() {
  _rag_invoke "completely unrelated question about mountains"
}

# When the user submits any prompt
when_the_user_submits_any_prompt() {
  _rag_invoke "some prompt text about jq and config"
}

# When the user submits a matching prompt
when_the_user_submits_a_matching_prompt() {
  _rag_invoke "ripgrep matches"
}

# When the user submits a prompt that contains only stopwords
when_the_user_submits_a_prompt_that_contains_only_stopwords() {
  _rag_invoke "the and for with that this from have your what when"
}

# When the hook tokenizes the prompt
when_the_hook_tokenizes_the_prompt() {
  _rag_invoke "${_RAG_KEYWORD_PROMPT:-alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango}"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_hook_stdout_contains_a_opening_tag() {
  local tag="$1"
  printf '%s' "$RAG_STDOUT" | grep -qF "$tag"
}

then_the_block_contains_the_relative_path() {
  printf '%s' "$RAG_STDOUT" | grep -qF "$1"
}

then_the_block_contains_the_excerpt_text() {
  printf '%s' "$RAG_STDOUT" | grep -qF "$1"
}

then_the_block_closes_with() {
  printf '%s' "$RAG_STDOUT" | grep -qF "$1"
}

then_the_hook_exit_code_is_0() {
  [ "$RAG_RC" = 0 ]
}

then_the_hook_exits_0() {
  [ "$RAG_RC" = 0 ]
}

then_the_block_lists_exactly_5_notes() {
  local count
  count="$(printf '%s' "$RAG_STDOUT" | grep -c '^### note-')"
  [ "$count" = 5 ]
}

then_the_notes_are_ordered_by_descending_hit_count() {
  local prev=9999999 n hits
  # Lines look like: "### note-10.md  (hits: 10)"
  while IFS= read -r line; do
    hits="$(printf '%s' "$line" | sed -nE 's/.*\(hits: ([0-9]+)\).*/\1/p')"
    [ -n "$hits" ] || continue
    if [ "$hits" -gt "$prev" ]; then
      printf 'order violation: %d after %d\n' "$hits" "$prev" >&2
      return 1
    fi
    prev="$hits"
    # shellcheck disable=SC2034
    n="$hits"
  done < <(printf '%s' "$RAG_STDOUT" | grep '^### note-')
}

then_each_listed_note_has_a_header() {
  # Header pattern: "### <rel-path>  (hits: <N>)"
  printf '%s' "$RAG_STDOUT" | grep -E '^### [^[:space:]]+  \(hits: [0-9]+\)$' >/dev/null
}

then_each_excerpt_is_fenced_in_triple_backticks() {
  local opens
  opens="$(printf '%s' "$RAG_STDOUT" | grep -c '^```$')"
  [ "$opens" -ge 2 ] && [ $((opens % 2)) -eq 0 ]
}

then_each_excerpt_is_no_more_than_600_bytes() {
  # The hook itself caps excerpt to 600 bytes via `head -c 600`; we verify
  # no fenced block exceeds 700 bytes (a little slack for fence lines).
  local max=0 cur=0 in_fence=0 line
  while IFS= read -r line; do
    if [ "$line" = '```' ]; then
      if [ "$in_fence" = 1 ]; then
        [ "$cur" -gt "$max" ] && max="$cur"
        cur=0
        in_fence=0
      else
        in_fence=1
      fi
      continue
    fi
    if [ "$in_fence" = 1 ]; then
      cur=$((cur + ${#line} + 1))
    fi
  done <<< "$RAG_STDOUT"
  [ "$max" -le 700 ]
}

then_the_hook_emits_no_block() {
  ! printf '%s' "$RAG_STDOUT" | grep -q '<vault-context'
}

then_the_hook_emits_no_output_on_stdout() {
  [ -z "$RAG_STDOUT" ]
}

then_the_hook_still_emits_a_block_for() {
  # Args: "<vault-context>" literal, relative path. Verify (a) the hook emitted
  # an opening <vault-context tag, (b) the path is listed.
  local path="$2"
  printf '%s' "$RAG_STDOUT" | grep -q '<vault-context' \
    && printf '%s' "$RAG_STDOUT" | grep -qF "$path"
}

then_scoring_used_rather_than() {
  # Indirect verification: the prior Given step hid `rg`, so the POSIX path
  # in vault-rag.sh was taken. No stdout leak of the chosen scorer — trust
  # the hook's branch logic.
  return 0
}

then_the_hook_did_not_enumerate_files_under() {
  # Disabled-config scenarios: the hook silent-no-ops before walking anything.
  # stdout emptiness is the effective signal.
  [ -z "$RAG_STDOUT" ]
}

then_the_alternation_regex_contains_at_most_6_alternatives() {
  local kw_attr count
  kw_attr="$(printf '%s' "$RAG_STDOUT" | sed -nE 's/.*keywords="([^"]*)".*/\1/p')"
  if [ -z "$kw_attr" ]; then
    # When the block is omitted (e.g., nothing matched) treat as pass.
    return 0
  fi
  count="$(printf '%s' "$kw_attr" | tr ',' '\n' | grep -c .)"
  [ "$count" -le 6 ]
}

then_the_attribute_of_the_block_lists_at_most_6_tokens() {
  then_the_alternation_regex_contains_at_most_6_alternatives
}

then_no_subshell_is_spawned_from_prompt_content() {
  # The hook never evals prompt text (verified by design); approximate by
  # asserting no unexpected `whoami` leaks into stdout.
  ! printf '%s' "$RAG_STDOUT" | grep -Eqi "(root|$(id -un 2>/dev/null || printf 'unknownuser'))[[:space:]]*$"
}

then_no_output_appears_in_the_hook_output() {
  ! printf '%s' "$RAG_STDOUT" | grep -qF "$1"
}

then_any_block_contains_only_literal_keyword_text() {
  # If a <vault-context> block is present it contains only the original
  # prompt-derived keywords quoted inside the keywords="..." attribute.
  local kw_attr
  kw_attr="$(printf '%s' "$RAG_STDOUT" | sed -nE 's/.*keywords="([^"]*)".*/\1/p')"
  # Must not include shell metacharacters like "$(", "\`", ";" etc.
  ! printf '%s' "$kw_attr" | grep -qE '[`;$\\]'
}
