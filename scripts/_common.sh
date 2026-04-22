#!/usr/bin/env bash
# Shared preamble for obsidian-memory hook scripts.
#
# Usage (from the top of each hook):
#   . "$(dirname "$0")/_common.sh"
#   om_load_config rag       # or: distill — gates on .<feature>.enabled
#   PAYLOAD="$(om_read_payload)" || exit 0
#
# On success, exports: VAULT, CONFIG. On any failure (missing deps, missing
# config, disabled flag, empty payload) the loader exits 0 itself — a broken
# hook must never block the user.

set -u
trap 'exit 0' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

om_load_config() {
  local feature="$1"
  command -v jq >/dev/null 2>&1 || exit 0
  [ -r "$CONFIG" ] || exit 0

  local enabled_expr=".${feature}.enabled != false"
  IFS=$'\t' read -r VAULT ENABLED < <(
    jq -r "[.vaultPath // \"\", ($enabled_expr | tostring)] | @tsv" "$CONFIG" 2>/dev/null
  )
  [ -n "${VAULT:-}" ] || exit 0
  [ -d "$VAULT" ] || exit 0
  [ "${ENABLED:-}" = "true" ] || exit 0
  export VAULT
}

om_read_payload() {
  local payload
  payload="$(cat)"
  [ -n "$payload" ] || return 1
  printf '%s' "$payload"
}

# basename($1), lowercased, non-alphanumerics → '-', collapsed, trimmed,
# length-capped at 60 characters. Truncation may expose a trailing hyphen
# (when char 60 is '-'); a final sed strip handles that case.
om_slug() {
  basename "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-|-$//g' \
    | cut -c1-60 \
    | sed -E 's/-$//'
}

# Usage:  _om_slug_in_csv "$slug" "$csv"   (returns 0 if present, 1 if not)
_om_slug_in_csv() {
  local needle="$1" csv="$2"
  [ -n "$csv" ] || return 1
  local stripped
  stripped="$(printf '%s' "$csv" | tr -d '"')"
  local IFS_SAVED="$IFS"
  local found=1
  IFS=','
  # Disable globbing during word-splitting so an unexpected `*`/`?`/`[` in a
  # future slug charset can never trigger filesystem expansion.
  set -f
  # shellcheck disable=SC2086
  set -- $stripped
  set +f
  IFS="$IFS_SAVED"
  local item
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      found=0
      break
    fi
  done
  return "$found"
}

# _om_read_projects_policy — prints three newline-separated fields on stdout:
#   1. mode           (coerced to "all" when unknown)
#   2. excluded_csv   (jq @csv; empty string when array is empty)
#   3. allowed_csv    (same)
# Malformed shapes produce a single stderr warning per field. Shared by
# om_project_allowed and om_policy_state. Newline-delimited (not tab) because
# bash `read` with whitespace IFS collapses consecutive delimiters, which
# would lose empty fields.
_om_read_projects_policy() {
  if [ ! -r "$CONFIG" ]; then
    printf 'all\n\n\n'
    return 0
  fi
  local mode excluded allowed
  { IFS= read -r mode; IFS= read -r excluded; IFS= read -r allowed; } < <(
    jq -r '
      (.projects.mode // "all"),
      (
        if .projects.excluded == null then ""
        elif (.projects.excluded | type) == "array" then (.projects.excluded | @csv)
        else "__INVALID__" end
      ),
      (
        if .projects.allowed == null then ""
        elif (.projects.allowed | type) == "array" then (.projects.allowed | @csv)
        else "__INVALID__" end
      )
    ' "$CONFIG" 2>/dev/null
  )
  mode="${mode:-all}"

  case "$mode" in
    all|allowlist) ;;
    *)
      printf '[%s] projects.mode="%s" — treating as "all"\n' "$(basename "${0:-om}")" "$mode" >&2
      mode="all"
      ;;
  esac

  if [ "$excluded" = "__INVALID__" ]; then
    printf '[%s] projects.excluded is not an array — treating as []\n' "$(basename "${0:-om}")" >&2
    excluded=""
  fi
  if [ "$allowed" = "__INVALID__" ]; then
    printf '[%s] projects.allowed is not an array — treating as []\n' "$(basename "${0:-om}")" >&2
    allowed=""
  fi

  printf '%s\n%s\n%s\n' "$mode" "$excluded" "$allowed"
}

# om_policy_state "$CWD" — echoes the current policy outcome for $CWD as
# exactly one of: all | excluded | allowlist-hit | allowlist-miss.
# Used by vault-session-start.sh to take the per-session snapshot.
om_policy_state() {
  local cwd="${1:-$PWD}"
  local slug
  slug="$(om_slug "$cwd")"
  if [ -z "$slug" ]; then
    printf 'all\n'
    return 0
  fi

  local mode excluded allowed
  { IFS= read -r mode; IFS= read -r excluded; IFS= read -r allowed; } < <(_om_read_projects_policy)

  if [ "$mode" = "all" ]; then
    if _om_slug_in_csv "$slug" "$excluded"; then
      printf 'excluded\n'
    else
      printf 'all\n'
    fi
    return 0
  fi

  if _om_slug_in_csv "$slug" "$allowed"; then
    printf 'allowlist-hit\n'
  else
    printf 'allowlist-miss\n'
  fi
}

# om_project_allowed "$CWD" — return 0 if the project is permitted, 1 if not.
# Missing / malformed shape → permissive default (mode=all, empty lists).
# Never exits on its own.
om_project_allowed() {
  local state
  state="$(om_policy_state "${1:-$PWD}")"
  case "$state" in
    excluded|allowlist-miss) return 1 ;;
    *) return 0 ;;
  esac
}

# --- Template resolution, frontmatter split, variable substitution ---

# om_plugin_root — echoes the absolute path to the plugin root. Derived from
# this file's location (scripts/_common.sh → plugin-root). Keeps the template
# path resolution independent of the caller's $0.
om_plugin_root() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
}

# _om_resolve_to_home <path> — absolute-or-$HOME-relative path resolver.
# Echoes the input unchanged if it begins with `/`; otherwise prefixes $HOME.
# Empty input returns empty (caller treats that as "not configured").
_om_resolve_to_home() {
  local raw="${1-}"
  [ -n "$raw" ] || return 0
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    *)  printf '%s/%s' "$HOME" "$raw" ;;
  esac
}

# _om_read_distill_template_paths <slug> — prints two newline-separated fields:
# the per-project override path (or empty) and the global path (or empty).
# Both are already $HOME-resolved. Silent on any jq / config error.
_om_read_distill_template_paths() {
  local slug="${1-}"
  local override_raw="" global_raw=""
  if [ -r "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    { IFS= read -r override_raw; IFS= read -r global_raw; } < <(
      jq -r --arg slug "$slug" '
        (.projects.overrides[$slug].distill.template_path // ""),
        (.distill.template_path // "")
      ' "$CONFIG" 2>/dev/null
    )
  fi
  printf '%s\n%s\n' \
    "$(_om_resolve_to_home "$override_raw")" \
    "$(_om_resolve_to_home "$global_raw")"
}

# om_render <text> — substitute the six whitelisted template tokens in <text>.
#
# Reads substitution values from the caller's environment:
#   SLUG            → {{project_slug}}
#   NOW_DATE        → {{date}}
#   NOW_TIME        → {{time}}
#   SESSION_ID      → {{session_id}}
#   TRANSCRIPT      → {{transcript_path}}
#   CONVO           → {{transcript}}
#
# Uses a single `jq -Rn` invocation with chained `gsub` calls. Non-whitelisted
# `{{…}}` tokens and any shell-looking syntax (`$VAR`, backticks, `$(…)`,
# `${…}`) pass through literally — jq never evaluates template content as
# shell. If jq fails (rare: filesystem error), echoes the input unchanged and
# returns 0 so a substitution glitch never blocks the hook.
om_render() {
  local text="${1-}"
  local rendered
  if ! rendered="$(
    jq -Rrn \
      --arg text          "$text" \
      --arg project_slug  "${SLUG-}" \
      --arg date          "${NOW_DATE-}" \
      --arg time          "${NOW_TIME-}" \
      --arg session_id    "${SESSION_ID-}" \
      --arg transcript_path "${TRANSCRIPT-}" \
      --arg transcript    "${CONVO-}" \
      '$text
       | gsub("\\{\\{project_slug\\}\\}";    $project_slug)
       | gsub("\\{\\{date\\}\\}";            $date)
       | gsub("\\{\\{time\\}\\}";            $time)
       | gsub("\\{\\{session_id\\}\\}";      $session_id)
       | gsub("\\{\\{transcript_path\\}\\}"; $transcript_path)
       | gsub("\\{\\{transcript\\}\\}";      $transcript)' 2>/dev/null
  )"; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s' "$rendered"
}

# om_split_frontmatter <text> — split <text> into (optional) YAML frontmatter
# and body regions, joined by a single 0x1E (record separator) byte:
#   <frontmatter><0x1E><body>
#
# Detection: the first non-blank line must be exactly `---`, AND a subsequent
# line must also be exactly `---`. The frontmatter region is inclusive of both
# `---` lines; the body begins on the line after the closing `---`. A
# malformed template (opening `---` without a closing `---`) is treated as
# having no frontmatter — the whole input falls into the body region.
#
# Implementation is POSIX awk — no bash 4+ features.
om_split_frontmatter() {
  local text="${1-}"
  printf '%s' "$text" | awk '
    BEGIN { state = "scan"; fm = ""; body = "" }
    {
      if (state == "scan") {
        if ($0 ~ /^[[:space:]]*$/) {
          fm = fm $0 "\n"
          next
        }
        if ($0 == "---") {
          fm = fm $0 "\n"
          state = "fm"
          next
        }
        state = "body"
        body = $0 "\n"
        next
      }
      if (state == "fm") {
        fm = fm $0 "\n"
        if ($0 == "---") {
          state = "after_fm"
        }
        next
      }
      if (state == "after_fm" || state == "body") {
        body = body $0 "\n"
        state = "body"
        next
      }
    }
    END {
      if (state == "after_fm" || state == "body") {
        # Either a full FM was captured (after_fm) and body may be empty, or we
        # landed in body directly (no FM). Both emit fm<0x1E>body.
        printf "%s\x1e%s", fm, body
      } else {
        # state == "scan" (blank-only input) or state == "fm" (unterminated FM)
        # → treat as no-frontmatter, body = full input.
        printf "\x1e%s", fm
      }
    }
  '
}

# om_resolve_distill_template <slug> — echoes the absolute path to the
# distillation template that should be used for <slug>.
#
# Resolution order:
#   1. projects.overrides.<slug>.distill.template_path
#   2. distill.template_path
#   3. <plugin-root>/templates/default-distillation.md
#
# A configured path is used only when [ -r <path> ] && [ -s <path> ] (readable
# regular file, non-empty). When a configured path fails that check, exactly
# one stderr line is emitted identifying which scope held the bad path, and
# resolution falls through to the next tier. Relative paths in config are
# resolved against $HOME.
#
# Returns 0 always — the bundled default is an install-time invariant.
om_resolve_distill_template() {
  local slug="${1-}"
  local override_path global_path
  { IFS= read -r override_path; IFS= read -r global_path; } < <(
    _om_read_distill_template_paths "$slug"
  )

  local logged=0
  if [ -n "$override_path" ]; then
    if [ -r "$override_path" ] && [ -s "$override_path" ]; then
      printf '%s' "$override_path"
      return 0
    fi
    printf '[vault-distill.sh] projects.overrides.%s.distill.template_path=%s unreadable; falling back to default template\n' \
      "$slug" "$override_path" >&2
    logged=1
  fi

  if [ -n "$global_path" ]; then
    if [ -r "$global_path" ] && [ -s "$global_path" ]; then
      printf '%s' "$global_path"
      return 0
    fi
    if [ "$logged" -eq 0 ]; then
      printf '[vault-distill.sh] distill.template_path=%s unreadable; falling back to default template\n' \
        "$global_path" >&2
    fi
  fi

  printf '%s/templates/default-distillation.md' "$(om_plugin_root)"
  return 0
}

# om_describe_distill_template <slug> — echoes a doctor-oriented descriptor
# string for the active template, without emitting the stderr warning
# om_resolve_distill_template would produce on an unreadable configured path.
#
# Returns one of:
#   default (bundled)
#   global: <path>
#   project-override(<slug>): <path>
#   configured but unreadable — falling back to default
om_describe_distill_template() {
  local slug="${1-}"
  local override_path global_path
  { IFS= read -r override_path; IFS= read -r global_path; } < <(
    _om_read_distill_template_paths "$slug"
  )

  if [ -n "$override_path" ]; then
    if [ -r "$override_path" ] && [ -s "$override_path" ]; then
      printf 'project-override(%s): %s' "$slug" "$override_path"
    else
      printf 'configured but unreadable — falling back to default'
    fi
    return 0
  fi

  if [ -n "$global_path" ]; then
    if [ -r "$global_path" ] && [ -s "$global_path" ]; then
      printf 'global: %s' "$global_path"
    else
      printf 'configured but unreadable — falling back to default'
    fi
    return 0
  fi

  printf 'default (bundled)'
}
