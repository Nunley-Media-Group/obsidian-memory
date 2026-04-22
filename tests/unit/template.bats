#!/usr/bin/env bats

# tests/unit/template.bats — unit tests for the configurable-template helpers
# added in issue #7: om_render, om_split_frontmatter, om_resolve_distill_template.
#
# Each test sources scripts/_common.sh in a fresh subshell with a scratch HOME
# so the operator's real ~/.claude/obsidian-memory/config.json is never read.

setup() {
  load '../helpers/scratch'
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory"
  COMMON="$PLUGIN_ROOT/scripts/_common.sh"
  export COMMON
  BUNDLED="$PLUGIN_ROOT/templates/default-distillation.md"
  export BUNDLED
}

teardown() { assert_home_untouched; }

_write_min_config() {
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] }
}
EOF
}

# ---------------------------------------------------------------------------
# om_render — whitelisted variable substitution
# ---------------------------------------------------------------------------

@test "om_render: replaces each of the six whitelisted tokens" {
  run bash -c '
    . "$0"
    SLUG=widgets NOW_DATE=2026-04-22 NOW_TIME=12:34:56 SESSION_ID=abc \
      TRANSCRIPT=/tmp/t.jsonl CONVO="USER-BODY"
    om_render "# {{project_slug}} on {{date}} at {{time}} session {{session_id}} from {{transcript_path}}
{{transcript}}"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# widgets on 2026-04-22 at 12:34:56 session abc from /tmp/t.jsonl"* ]]
  [[ "$output" == *"USER-BODY"* ]]
}

@test "om_render: non-whitelisted {{foo}} tokens pass through verbatim" {
  run bash -c '. "$0"; SLUG=x om_render "{{user_email}} and {{custom_thing}}"' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"{{user_email}}"* ]]
  [[ "$output" == *"{{custom_thing}}"* ]]
}

@test "om_render: shell-looking syntax is preserved literally" {
  # Single-quote to protect $HOME from bash expansion before om_render sees it.
  run bash -c '. "$0"; SLUG=x om_render "$1"' "$COMMON" \
    '$HOME `whoami` $(date) ${PATH} — all literal'
  [ "$status" -eq 0 ]
  [ "$output" = '$HOME `whoami` $(date) ${PATH} — all literal' ]
}

@test "om_render: empty input returns empty output" {
  run bash -c '. "$0"; SLUG=x om_render ""' "$COMMON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "om_render: replaces every occurrence of {{project_slug}}" {
  run bash -c '. "$0"; SLUG=widgets om_render "{{project_slug}}-{{project_slug}}-{{project_slug}}"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "widgets-widgets-widgets" ]
}

@test "om_render: regex footgun — {{project_slugger}} is NOT partial-matched" {
  run bash -c '. "$0"; SLUG=widgets om_render "{{project_slugger}} vs {{project_slug}}"' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"{{project_slugger}}"* ]]
  [[ "$output" == *"widgets"* ]]
  # The "ger" suffix must NOT have been silently eaten.
  [[ "$output" == *"{{project_slugger}} vs widgets"* ]]
}

@test "om_render: stray {{ or }} braces outside whitelisted token pass through" {
  run bash -c '. "$0"; SLUG=widgets om_render "open {{ only and close }} only"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "open {{ only and close }} only" ]
}

# ---------------------------------------------------------------------------
# om_split_frontmatter — YAML frontmatter detection and split
# ---------------------------------------------------------------------------

@test "om_split_frontmatter: no frontmatter → empty FM, full body" {
  run bash -c '
    . "$0"
    out="$(om_split_frontmatter "# body only\nline two"; printf x)"
    out="${out%x}"
    # field 1 before 0x1e is FM; field 2 after is body.
    fm="${out%%$(printf "\x1e")*}"
    body="${out#*$(printf "\x1e")}"
    printf "FM=[%s]\nBODY=[%s]" "$fm" "$body"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FM=[]"* ]]
  [[ "$output" == *"BODY=[# body only"* ]]
}

@test "om_split_frontmatter: well-formed frontmatter is captured fully" {
  run bash -c '
    . "$0"
    input="$(printf -- "---\ntitle: hello\ntags: [a]\n---\n\n# Heading\nbody")"
    out="$(om_split_frontmatter "$input"; printf x)"
    out="${out%x}"
    fm="${out%%$(printf "\x1e")*}"
    body="${out#*$(printf "\x1e")}"
    printf "FM=<<%s>>\nBODY=<<%s>>" "$fm" "$body"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FM=<<---"* ]]
  [[ "$output" == *"title: hello"* ]]
  [[ "$output" == *"BODY=<<"* ]]
  [[ "$output" == *"# Heading"* ]]
}

@test "om_split_frontmatter: malformed (opening --- without closing) → no FM, full body" {
  run bash -c '
    . "$0"
    input="$(printf -- "---\ntitle: x\nno closer here")"
    out="$(om_split_frontmatter "$input"; printf x)"
    out="${out%x}"
    fm="${out%%$(printf "\x1e")*}"
    printf "FM=[%s]" "$fm"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "FM=[]" ]
}

@test "om_split_frontmatter: frontmatter-only template (empty body after closing ---)" {
  run bash -c '
    . "$0"
    input="$(printf -- "---\ntitle: x\n---")"
    out="$(om_split_frontmatter "$input"; printf x)"
    out="${out%x}"
    fm="${out%%$(printf "\x1e")*}"
    body="${out#*$(printf "\x1e")}"
    printf "FM_HAS_DELIM=%s\nBODY_LEN=%d" \
      "$(printf "%s" "$fm" | grep -c "^---$")" "${#body}"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FM_HAS_DELIM=2"* ]]
  [[ "$output" == *"BODY_LEN=0"* ]]
}

# ---------------------------------------------------------------------------
# om_resolve_distill_template — resolution + fallback + stderr logging
# ---------------------------------------------------------------------------

@test "om_resolve_distill_template: no config → bundled default" {
  rm -f "$CONFIG"
  run bash -c '. "$0"; om_resolve_distill_template "any-slug"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$BUNDLED" ]
}

@test "om_resolve_distill_template: no template_path set → bundled default" {
  _write_min_config
  run bash -c '. "$0"; om_resolve_distill_template "any-slug"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$BUNDLED" ]
}

@test "om_resolve_distill_template: readable global template wins over default" {
  _write_min_config
  local tpl="$BATS_TEST_TMPDIR/my-template.md"
  printf 'some content\n' > "$tpl"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg p "$tpl" '.distill.template_path = $p' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "any-slug"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$tpl" ]
}

@test "om_resolve_distill_template: per-project override wins over global" {
  _write_min_config
  local g="$BATS_TEST_TMPDIR/global.md"
  local o="$BATS_TEST_TMPDIR/override.md"
  printf 'g\n' > "$g"
  printf 'o\n' > "$o"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg g "$g" --arg o "$o" \
    '.distill.template_path = $g
     | .projects.overrides = {"widgets": {"distill": {"template_path": $o}}}' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "widgets"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$o" ]
}

@test "om_resolve_distill_template: mismatched per-project slug falls through to global" {
  _write_min_config
  local g="$BATS_TEST_TMPDIR/global.md"
  local o="$BATS_TEST_TMPDIR/override.md"
  printf 'g\n' > "$g"
  printf 'o\n' > "$o"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg g "$g" --arg o "$o" \
    '.distill.template_path = $g
     | .projects.overrides = {"widgets": {"distill": {"template_path": $o}}}' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "other-project"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$g" ]
}

@test "om_resolve_distill_template: unreadable global template → one stderr line + bundled default" {
  _write_min_config
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq '.distill.template_path = "/nope/does-not-exist.md"' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "any-slug" 2>&1 >/dev/null' "$COMMON"
  [[ "$output" == *"distill.template_path=/nope/does-not-exist.md unreadable; falling back to default template"* ]]

  run bash -c '. "$0"; om_resolve_distill_template "any-slug" 2>/dev/null' "$COMMON"
  [ "$output" = "$BUNDLED" ]
}

@test "om_resolve_distill_template: empty configured file → one stderr line + bundled default" {
  _write_min_config
  local tpl="$BATS_TEST_TMPDIR/empty.md"
  : > "$tpl"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg p "$tpl" '.distill.template_path = $p' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "any-slug" 2>&1 >/dev/null' "$COMMON"
  [[ "$output" == *"unreadable; falling back to default template"* ]]

  run bash -c '. "$0"; om_resolve_distill_template "any-slug" 2>/dev/null' "$COMMON"
  [ "$output" = "$BUNDLED" ]
}

@test "om_resolve_distill_template: unreadable per-project override → project-scoped stderr line" {
  _write_min_config
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq '.projects.overrides = {"widgets": {"distill": {"template_path": "/nope/override.md"}}}' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "widgets" 2>&1 >/dev/null' "$COMMON"
  [[ "$output" == *"projects.overrides.widgets.distill.template_path=/nope/override.md unreadable"* ]]
}

@test "om_resolve_distill_template: relative config path is resolved against \$HOME" {
  _write_min_config
  mkdir -p "$HOME/.claude/obsidian-memory/templates"
  printf 'tpl\n' > "$HOME/.claude/obsidian-memory/templates/rel.md"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq '.distill.template_path = ".claude/obsidian-memory/templates/rel.md"' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_resolve_distill_template "any"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude/obsidian-memory/templates/rel.md" ]
}

# ---------------------------------------------------------------------------
# om_describe_distill_template — doctor-oriented descriptor (no stderr)
# ---------------------------------------------------------------------------

@test "om_describe_distill_template: no config key → 'default (bundled)'" {
  _write_min_config
  run bash -c '. "$0"; om_describe_distill_template "any"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "default (bundled)" ]
}

@test "om_describe_distill_template: readable global path → 'global: <path>'" {
  _write_min_config
  local tpl="$BATS_TEST_TMPDIR/mine.md"
  printf 'tpl\n' > "$tpl"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg p "$tpl" '.distill.template_path = $p' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_describe_distill_template "any"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "global: $tpl" ]
}

@test "om_describe_distill_template: readable per-project → 'project-override(<slug>): <path>'" {
  _write_min_config
  local tpl="$BATS_TEST_TMPDIR/override.md"
  printf 'tpl\n' > "$tpl"
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq --arg p "$tpl" '.projects.overrides = {"widgets": {"distill": {"template_path": $p}}}' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_describe_distill_template "widgets"' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "project-override(widgets): $tpl" ]
}

@test "om_describe_distill_template: unreadable configured path → 'configured but unreadable'" {
  _write_min_config
  local tmp
  tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
  jq '.distill.template_path = "/nope/absent.md"' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  run bash -c '. "$0"; om_describe_distill_template "any"' "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"configured but unreadable"* ]]
}
