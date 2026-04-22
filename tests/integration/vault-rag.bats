#!/usr/bin/env bats

# tests/integration/vault-rag.bats — end-to-end coverage of the
# UserPromptSubmit hook (scripts/vault-rag.sh) for the v0.1.0 keyword backend.
# Each @test exercises one acceptance criterion (AC1–AC12) from
# specs/feature-rag-prompt-injection/requirements.md. With no `rag.backend`
# key in config the dispatcher delegates to vault-rag-keyword.sh unchanged.

setup() {
  load '../helpers/scratch'

  RAG="$PLUGIN_ROOT/scripts/vault-rag.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export RAG CONFIG

  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  HELPERS_DIR="$PLUGIN_ROOT/tests/helpers"
  export HELPERS_DIR
  # shellcheck disable=SC1091
  . "$PLUGIN_ROOT/tests/features/steps/common.sh"
}

teardown() { assert_home_untouched; }

_write_config() {
  # $1 = optional jq filter applied to a permissive v0.1 baseline config.
  local filter="${1:-.}"
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true }
}
EOF
  if [ "$filter" != "." ]; then
    local tmp
    tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
    jq --indent 2 "$filter" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

_run_rag() {
  # $1 = prompt string
  local payload
  payload="$(jq -n --arg p "$1" '{prompt:$p}')"
  printf '%s' "$payload" | "$RAG"
}

_seed_note() {
  # $1 = relative path under $VAULT, $2 = body
  local rel="$1" body="$2"
  mkdir -p "$(dirname "$VAULT/$rel")"
  printf '%s\n' "$body" > "$VAULT/$rel"
}

# --- AC1: vault note contains a keyword from the prompt --------------------

@test "AC1: keyword match emits a <vault-context> block listing the note and excerpt" {
  _write_config
  _seed_note "my-note.md" "jq is used for config parsing"

  run _run_rag "How do I use jq for config parsing?"

  [ "$status" -eq 0 ]
  [[ "$output" == *'<vault-context source="obsidian"'* ]]
  [[ "$output" == *"my-note.md"* ]]
  [[ "$output" == *"jq is used for config parsing"* ]]
  [[ "$output" == *"</vault-context>"* ]]
}

# --- AC2: no matching notes --------------------------------------------------

@test "AC2: no matching vault notes produces empty stdout and exit 0" {
  _write_config
  _seed_note "unrelated.md" "just some static words about planets and oceans"

  run _run_rag "completely disjoint prompt about magnetism"

  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

# --- AC3: rg not on PATH — POSIX fallback -----------------------------------

@test "AC3: hook still emits a block when rg is not on PATH (POSIX fallback)" {
  _write_config
  _seed_note "my-note.md" "ripgrep not needed when grep is present"

  hide_binary rg
  [ -z "$(command -v rg)" ]

  run _run_rag "ripgrep fallback"

  [ "$status" -eq 0 ]
  [[ "$output" == *'<vault-context source="obsidian"'* ]]
  [[ "$output" == *"my-note.md"* ]]
}

# --- AC4: RAG disabled via config flag --------------------------------------

@test "AC4: rag.enabled=false produces empty stdout without reading the vault" {
  _write_config '.rag.enabled = false'
  _seed_note "my-note.md" "jq is used for config parsing"

  run _run_rag "jq config parsing"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC5: auto-memory symlink path is excluded (feedback-loop guard) --------

@test "AC5: matches under claude-memory/projects/** are excluded" {
  _write_config
  # The setup above pointed $VAULT/claude-memory/projects at $HOME/.claude/projects.
  # Seed a JSONL transcript under that symlinked tree — it must NOT match.
  mkdir -p "$HOME/.claude/projects/some-project"
  printf '%s\n' "jq appears here in a transcript line" \
    > "$HOME/.claude/projects/some-project/2026-04-18.jsonl"

  run _run_rag "jq config parsing"

  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

# --- AC6: Obsidian metadata directories are excluded ------------------------

@test "AC6: .obsidian/ and .trash/ are excluded from scoring" {
  _write_config
  mkdir -p "$VAULT/.obsidian" "$VAULT/.trash"
  printf 'ripgrep appears in workspace metadata\n' > "$VAULT/.obsidian/workspace.json"
  printf 'ripgrep appears in a deleted note\n' > "$VAULT/.trash/deleted-note.md"

  run _run_rag "ripgrep metadata"

  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

# --- AC7: missing jq dependency ---------------------------------------------

@test "AC7: missing jq exits 0 silently and delivers the prompt unchanged" {
  _write_config
  _seed_note "my-note.md" "jq is used for config parsing"

  hide_binary jq
  [ -z "$(command -v jq)" ]

  # No jq means we cannot build the JSON payload with jq -n; hand-craft it.
  run bash -c 'printf "%s" "{\"prompt\":\"jq config parsing\"}" | "$0"' "$RAG"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC8: missing config file -----------------------------------------------

@test "AC8: missing config.json exits 0 silently" {
  [ ! -e "$CONFIG" ]

  run _run_rag "anything"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC9: stopwords-only prompt emits no block ------------------------------

@test "AC9: all-stopword prompt produces no <vault-context> block" {
  _write_config
  _seed_note "anything.md" "the and for with that this from have"

  run _run_rag "the and for with that this from have"

  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

# --- AC10: keyword cap of 6 is enforced -------------------------------------

@test "AC10: 20-token prompt is capped to 6 keywords in the output attribute" {
  _write_config
  local twenty="alpha bravo charlie delta eecho foxtrot golfo hotel india juliet kilotango limat mikes november oscar papayas quebec romeos sierra tangos"
  _seed_note "tokens.md" "$twenty"

  run _run_rag "$twenty"

  [ "$status" -eq 0 ]
  [[ "$output" == *'<vault-context source="obsidian"'* ]]

  local kw_attr count
  kw_attr="$(printf '%s' "$output" | sed -nE 's/.*keywords="([^"]*)".*/\1/p' | head -n 1)"
  [ -n "$kw_attr" ]
  count="$(printf '%s' "$kw_attr" | tr ',' '\n' | grep -c .)"
  [ "$count" -le 6 ]
}

# --- AC11: top-5 ranking and excerpt format ---------------------------------

@test "AC11: top-5 ordered by descending hit count, with ### header + fenced excerpt" {
  _write_config
  local kw="sharedkeyword"
  local i n
  for i in {1..10}; do
    {
      n="$i"
      while [ "$n" -gt 0 ]; do
        printf '%s line %d\n' "$kw" "$n"
        n=$((n - 1))
      done
    } > "$VAULT/note-$i.md"
  done

  run _run_rag "$kw appears frequently"

  [ "$status" -eq 0 ]

  # Exactly five "### note-*.md" headers.
  local header_count
  header_count="$(printf '%s\n' "$output" | grep -Ec '^### note-.*\.md  \(hits: [0-9]+\)$')"
  [ "$header_count" -eq 5 ]

  # Each excerpt is fenced with ``` — open/close counts even, >= 10 (5 notes * 2).
  local fence_count
  fence_count="$(printf '%s\n' "$output" | grep -c '^```$')"
  [ "$fence_count" -ge 10 ]
  [ $((fence_count % 2)) -eq 0 ]

  # Hit counts appear in descending order (10, 9, 8, 7, 6).
  local hits_list expected
  hits_list="$(printf '%s\n' "$output" | sed -nE 's/^### note-[0-9]+\.md  \(hits: ([0-9]+)\)$/\1/p')"
  expected="$(printf '10\n9\n8\n7\n6\n')"
  [ "$hits_list" = "$expected" ]
}

# --- AC12: prompt-injection safety -------------------------------------------

@test "AC12: shell metacharacters in the prompt never spawn a subshell" {
  _write_config
  _seed_note "note.md" "safe keyword test content with injection filler"

  # shellcheck disable=SC2016  # literal shell metacharacters are the test fixture
  local sneaky='$(whoami) ; rm -rf /  `echo x`  '\''injection'\''  "quote"  injection'
  local user_marker
  user_marker="$(id -un)"
  run _run_rag "$sneaky"

  [ "$status" -eq 0 ]
  # Command substitution would surface the current username in the output.
  [[ "$output" != *"$user_marker"* ]]
  # The keywords attribute, if emitted, must contain only alphanumeric tokens.
  local kw_attr
  kw_attr="$(printf '%s' "$output" | sed -nE 's/.*keywords="([^"]*)".*/\1/p' | head -n 1)"
  if [ -n "$kw_attr" ]; then
    printf '%s' "$kw_attr" | grep -Ev '[`;$\\]' >/dev/null
  fi
}
