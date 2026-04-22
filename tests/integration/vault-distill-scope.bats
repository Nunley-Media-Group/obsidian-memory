#!/usr/bin/env bats

# tests/integration/vault-distill-scope.bats — SessionEnd hook honors the
# per-session policy snapshot (mid-session immunity, AC6) and falls back to
# the live config when no snapshot exists.

setup() {
  load '../helpers/scratch'
  DISTILL="$PLUGIN_ROOT/scripts/vault-distill.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  POLICY_DIR="$HOME/.claude/obsidian-memory/session-policy"
  export DISTILL CONFIG POLICY_DIR
  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects" "$POLICY_DIR"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"
  load '../helpers/fake-claude'
  install_fake_claude
}

teardown() { assert_home_untouched; }

_write_config() {
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

_seed_transcript() {
  # $1 = session_id → produces a >= 2KB transcript at the conventional path
  local sid="$1"
  local path="$HOME/.claude/projects/${sid}.jsonl"
  : > "$path"
  local body='{"type":"user","message":{"content":"discussion about implementation details and decisions"}}'
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    printf '%s\n' "$body" >> "$path"
  done
  printf '%s' "$path"
}

_run_distill() {
  # $1 = session_id, $2 = cwd
  local sid="$1" cwd="$2"
  local transcript
  transcript="$(_seed_transcript "$sid")"
  local payload
  payload="$(jq -n \
    --arg s "$sid" --arg c "$cwd" --arg t "$transcript" \
    '{session_id:$s, cwd:$c, transcript_path:$t, reason:"stop"}')"
  printf '%s' "$payload" | "$DISTILL"
}

# ---------------------------------------------------------------------------
# Snapshot-driven scope decisions (AC6)
# ---------------------------------------------------------------------------

@test "snapshot=excluded → exits 0, no session note written" {
  _write_config
  printf 'excluded\n' > "$POLICY_DIR/sess-A.state"
  mkdir -p "$BATS_TEST_TMPDIR/proj/acme"
  run _run_distill "sess-A" "$BATS_TEST_TMPDIR/proj/acme"
  [ "$status" -eq 0 ]
  [ ! -d "$VAULT/claude-memory/sessions/acme" ] \
    || [ -z "$(find "$VAULT/claude-memory/sessions/acme" -type f -name '*.md' 2>/dev/null)" ]
  # Snapshot consumed (removed) after read
  [ ! -e "$POLICY_DIR/sess-A.state" ]
}

@test "snapshot=allowlist-miss → exits 0, no session note written" {
  _write_config
  printf 'allowlist-miss\n' > "$POLICY_DIR/sess-B.state"
  mkdir -p "$BATS_TEST_TMPDIR/proj/random"
  run _run_distill "sess-B" "$BATS_TEST_TMPDIR/proj/random"
  [ "$status" -eq 0 ]
  [ ! -d "$VAULT/claude-memory/sessions/random" ] \
    || [ -z "$(find "$VAULT/claude-memory/sessions/random" -type f -name '*.md' 2>/dev/null)" ]
}

@test "snapshot=all + live config NOW excludes (mid-session) → distill still proceeds" {
  # AC6 mid-session immunity: snapshot taken at SessionStart wins over the
  # live config that was edited mid-session.
  _write_config '.projects.excluded = ["mid-project"]'
  printf 'all\n' > "$POLICY_DIR/sess-C.state"
  mkdir -p "$BATS_TEST_TMPDIR/proj/mid-project"
  run _run_distill "sess-C" "$BATS_TEST_TMPDIR/proj/mid-project"
  [ "$status" -eq 0 ]
  local notes
  notes="$(find "$VAULT/claude-memory/sessions/mid-project" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$notes" -ge 1 ]
  # Snapshot consumed after read.
  [ ! -e "$POLICY_DIR/sess-C.state" ]
}

@test "snapshot=allowlist-hit → distill proceeds normally" {
  _write_config
  printf 'allowlist-hit\n' > "$POLICY_DIR/sess-D.state"
  mkdir -p "$BATS_TEST_TMPDIR/proj/work-project"
  run _run_distill "sess-D" "$BATS_TEST_TMPDIR/proj/work-project"
  [ "$status" -eq 0 ]
  local notes
  notes="$(find "$VAULT/claude-memory/sessions/work-project" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$notes" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Fallback to live config when snapshot is missing
# ---------------------------------------------------------------------------

@test "no snapshot + live config excludes → distill skipped (fallback branch)" {
  _write_config '.projects.excluded = ["acme"]'
  mkdir -p "$BATS_TEST_TMPDIR/proj/acme"
  run _run_distill "sess-no-snap" "$BATS_TEST_TMPDIR/proj/acme"
  [ "$status" -eq 0 ]
  [ ! -d "$VAULT/claude-memory/sessions/acme" ] \
    || [ -z "$(find "$VAULT/claude-memory/sessions/acme" -type f -name '*.md' 2>/dev/null)" ]
}

@test "no snapshot + live config permissive → distill writes note" {
  _write_config
  mkdir -p "$BATS_TEST_TMPDIR/proj/free-project"
  run _run_distill "sess-free" "$BATS_TEST_TMPDIR/proj/free-project"
  [ "$status" -eq 0 ]
  local notes
  notes="$(find "$VAULT/claude-memory/sessions/free-project" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$notes" -ge 1 ]
}
