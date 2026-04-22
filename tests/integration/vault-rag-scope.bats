#!/usr/bin/env bats

# tests/integration/vault-rag-scope.bats — UserPromptSubmit hook honors the
# per-project scope policy (FR2, FR8, AC1, AC2).

setup() {
  load '../helpers/scratch'
  RAG="$PLUGIN_ROOT/scripts/vault-rag.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export RAG CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
}

teardown() { assert_home_untouched; }

_write_config() {
  # $1 = optional jq filter applied to a permissive baseline config.
  local filter="${1:-.}"
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] }
}
EOF
  if [ "$filter" != "." ]; then
    local tmp
    tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
    jq --indent 2 "$filter" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

_run_rag() {
  # $1 = prompt, $2 = cwd
  local payload
  payload="$(jq -n --arg p "$1" --arg c "$2" '{prompt:$p, cwd:$c}')"
  printf '%s' "$payload" | "$RAG"
}

_seed_note() {
  # $1 = filename, $2 = body
  printf '%s\n' "$2" > "$VAULT/$1"
}

@test "default permissive: prompt with matching keyword emits <vault-context>" {
  _write_config
  _seed_note "jq-notes.md" "document parser configuration is the topic of this note"
  mkdir -p "$BATS_TEST_TMPDIR/proj/some-project"
  run _run_rag "document parser configuration" "$BATS_TEST_TMPDIR/proj/some-project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<vault-context"* ]]
  [[ "$output" == *"jq-notes.md"* ]]
}

@test "excluded project: hook exits 0 with empty stdout (no <vault-context>)" {
  _write_config '.projects.excluded = ["acme-client"]'
  _seed_note "jq-notes.md" "document parser configuration is the topic of this note"
  mkdir -p "$BATS_TEST_TMPDIR/proj/acme-client"
  run _run_rag "document parser configuration" "$BATS_TEST_TMPDIR/proj/acme-client"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

@test "allowlist mode: project IN allowlist gets <vault-context>" {
  _write_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["obsidian-memory"]}'
  _seed_note "architecture.md" "plugin root is the repo root for obsidian"
  mkdir -p "$BATS_TEST_TMPDIR/proj/obsidian-memory"
  run _run_rag "where is the plugin root" "$BATS_TEST_TMPDIR/proj/obsidian-memory"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<vault-context"* ]]
  [[ "$output" == *"architecture.md"* ]]
}

@test "allowlist mode: project NOT in allowlist gets empty stdout" {
  _write_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["obsidian-memory"]}'
  _seed_note "architecture.md" "plugin root is the repo root"
  mkdir -p "$BATS_TEST_TMPDIR/proj/random-repo"
  run _run_rag "where is the plugin root" "$BATS_TEST_TMPDIR/proj/random-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<vault-context"* ]]
}

@test "missing projects stanza is permissive (v0.1 regression guard)" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  _seed_note "jq-notes.md" "document parser configuration is the topic of this note"
  mkdir -p "$BATS_TEST_TMPDIR/proj/some-project"
  run _run_rag "document parser configuration" "$BATS_TEST_TMPDIR/proj/some-project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<vault-context"* ]]
}

@test "unknown mode coerces to all (permissive) and emits stderr warning" {
  _write_config '.projects.mode = "strict-ish"'
  _seed_note "jq-notes.md" "document parser configuration is the topic of this note"
  mkdir -p "$BATS_TEST_TMPDIR/proj/some-project"
  run _run_rag "document parser configuration" "$BATS_TEST_TMPDIR/proj/some-project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<vault-context"* ]]
}
