#!/usr/bin/env bats

# tests/unit/common.bats — unit tests for scripts/_common.sh helpers
# (om_slug length-cap, om_project_allowed, om_policy_state, _om_slug_in_csv).
#
# Each test sources _common.sh in a fresh subshell with a scratch HOME so the
# operator's real ~/.claude/obsidian-memory/config.json is never read.

setup() {
  load '../helpers/scratch'
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export CONFIG
  mkdir -p "$HOME/.claude/obsidian-memory"
  COMMON="$PLUGIN_ROOT/scripts/_common.sh"
  export COMMON
}

teardown() { assert_home_untouched; }

_write_projects_config() {
  # $1 = jq filter to apply to base config
  local filter="$1"
  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true },
  "projects": { "mode": "all", "excluded": [], "allowed": [] }
}
EOF
  if [ -n "$filter" ]; then
    local tmp
    tmp="$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")"
    jq "$filter" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

# ---------------------------------------------------------------------------
# om_slug
# ---------------------------------------------------------------------------

@test "om_slug: short basename is unchanged" {
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "/Users/me/proj/obsidian-memory"
  [ "$status" -eq 0 ]
  [ "$output" = "obsidian-memory" ]
}

@test "om_slug: lowercases and collapses non-alphanumerics to hyphens" {
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "/Users/me/Some_Mixed-Case.Project"
  [ "$status" -eq 0 ]
  [ "$output" = "some-mixed-case-project" ]
}

@test "om_slug: caps at 60 characters" {
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" \
    "/Users/me/projects/My-Very-Long-Confidential_Client_Project_Name_With_Many_Characters"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 60 ]
  [[ "$output" =~ ^[a-z0-9-]+$ ]]
}

@test "om_slug: no leading or trailing hyphens" {
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "/path/--Hello--"
  [ "$status" -eq 0 ]
  case "$output" in
    -*|*-) return 1 ;;
  esac
}

@test "om_slug: deterministic across calls" {
  local input="/Users/me/projects/Some_Mixed-Case.Project"
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "$input"
  local first="$output"
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "$input"
  [ "$output" = "$first" ]
}

@test "om_slug: trailing hyphen exposed by truncation is stripped" {
  # Build a basename whose 60th char would be a hyphen after slugification.
  # Choose pattern: 59 alnum chars + '-' + tail → after collapse, 60th is '-'.
  local input="/path/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-extra"
  run bash -c '. "$0"; om_slug "$1"' "$COMMON" "$input"
  [ "$status" -eq 0 ]
  case "$output" in
    *-) return 1 ;;
  esac
  [ "${#output}" -le 60 ]
}

# ---------------------------------------------------------------------------
# om_project_allowed
# ---------------------------------------------------------------------------

@test "om_project_allowed: missing config is permissive (returns 0)" {
  rm -f "$CONFIG"
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/anything"
  [ "$output" = "PASS" ]
}

@test "om_project_allowed: missing projects stanza is permissive" {
  cat > "$CONFIG" <<EOF
{"vaultPath":"$VAULT","rag":{"enabled":true},"distill":{"enabled":true}}
EOF
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/random"
  [ "$output" = "PASS" ]
}

@test "om_project_allowed: mode=all + slug in excluded → denies" {
  _write_projects_config '.projects.excluded = ["acme-client"]'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/acme-client"
  [ "$output" = "DENY" ]
}

@test "om_project_allowed: mode=all + slug not in excluded → allows" {
  _write_projects_config '.projects.excluded = ["acme-client"]'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/other-project"
  [ "$output" = "PASS" ]
}

@test "om_project_allowed: mode=allowlist + slug in allowed → allows" {
  _write_projects_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["obsidian-memory"]}'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/obsidian-memory"
  [ "$output" = "PASS" ]
}

@test "om_project_allowed: mode=allowlist + slug not in allowed → denies" {
  _write_projects_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["obsidian-memory"]}'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/random-repo"
  [ "$output" = "DENY" ]
}

@test "om_project_allowed: unknown mode → coerced to all (permissive) with stderr warning" {
  _write_projects_config '.projects.mode = "strict-ish"'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/anything"
  [[ "$output" == *PASS* ]]
  [[ "$output" == *'projects.mode="strict-ish"'* ]]
}

@test "om_project_allowed: non-array excluded → coerced to []  (stderr warning)" {
  _write_projects_config '.projects.excluded = "not an array"'
  run bash -c '. "$0"; om_project_allowed "$1" && echo PASS || echo DENY' \
    "$COMMON" "/proj/anything"
  [[ "$output" == *PASS* ]]
  [[ "$output" == *"projects.excluded is not an array"* ]]
}

# ---------------------------------------------------------------------------
# om_policy_state
# ---------------------------------------------------------------------------

@test "om_policy_state: default mode → 'all'" {
  _write_projects_config ''
  run bash -c '. "$0"; om_policy_state "$1"' "$COMMON" "/proj/whatever"
  [ "$status" -eq 0 ]
  [ "$output" = "all" ]
}

@test "om_policy_state: mode=all + excluded hit → 'excluded'" {
  _write_projects_config '.projects.excluded = ["acme-client"]'
  run bash -c '. "$0"; om_policy_state "$1"' "$COMMON" "/proj/acme-client"
  [ "$output" = "excluded" ]
}

@test "om_policy_state: mode=allowlist + allowed hit → 'allowlist-hit'" {
  _write_projects_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["x"]}'
  run bash -c '. "$0"; om_policy_state "$1"' "$COMMON" "/proj/x"
  [ "$output" = "allowlist-hit" ]
}

@test "om_policy_state: mode=allowlist + miss → 'allowlist-miss'" {
  _write_projects_config '.projects = {"mode":"allowlist","excluded":[],"allowed":["x"]}'
  run bash -c '. "$0"; om_policy_state "$1"' "$COMMON" "/proj/y"
  [ "$output" = "allowlist-miss" ]
}

# ---------------------------------------------------------------------------
# _om_slug_in_csv (private but worth pinning)
# ---------------------------------------------------------------------------

@test "_om_slug_in_csv: matches a slug in a quoted CSV (jq @csv format)" {
  run bash -c '. "$0"; _om_slug_in_csv "$1" "$2" && echo HIT || echo MISS' \
    "$COMMON" "acme" '"acme","beta"'
  [ "$output" = "HIT" ]
}

@test "_om_slug_in_csv: empty list → MISS" {
  run bash -c '. "$0"; _om_slug_in_csv "$1" "$2" && echo HIT || echo MISS' \
    "$COMMON" "acme" ""
  [ "$output" = "MISS" ]
}

@test "_om_slug_in_csv: substring is not a hit (full-token match only)" {
  run bash -c '. "$0"; _om_slug_in_csv "$1" "$2" && echo HIT || echo MISS' \
    "$COMMON" "acm" '"acme"'
  [ "$output" = "MISS" ]
}
