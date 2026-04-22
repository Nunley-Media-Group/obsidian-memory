#!/usr/bin/env bash
# vault-distill.sh — SessionEnd hook.
# Reads the just-ended session's transcript, calls `claude -p` to produce a
# concise Obsidian note, and writes it under
# <vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md.

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
om_load_config distill

PAYLOAD="$(om_read_payload)" || exit 0

IFS=$'\t' read -r TRANSCRIPT CWD SESSION_ID REASON < <(
  printf '%s' "$PAYLOAD" \
    | jq -r '[.transcript_path // "", .cwd // "", .session_id // "unknown", .reason // "unknown"] | @tsv' 2>/dev/null
)

[ -n "$TRANSCRIPT" ] || exit 0
[ -n "$CWD" ] || CWD="$(pwd)"

# Per-project scope gate (snapshot-first, honors mid-session immunity).
#
# The SessionStart hook (vault-session-start.sh) wrote a one-line snapshot for
# this session_id so a scope edit made mid-session does NOT retroactively kill
# an in-flight distill. When the snapshot is missing (session predates upgrade
# or write failed) we fall back to the live config via om_project_allowed —
# best-effort, still honors "never blocks the user."
POLICY_DIR="${HOME}/.claude/obsidian-memory/session-policy"
SNAPSHOT="$POLICY_DIR/${SESSION_ID}.state"
STATE=""
if [ -r "$SNAPSHOT" ]; then
  STATE="$(head -n1 "$SNAPSHOT" 2>/dev/null)"
  rm -f "$SNAPSHOT" 2>/dev/null
fi

case "$STATE" in
  excluded|allowlist-miss)
    exit 0
    ;;
  all|allowlist-hit)
    :
    ;;
  *)
    om_project_allowed "$CWD" || exit 0
    ;;
esac

# Skip trivial sessions.
SIZE="$(wc -c <"$TRANSCRIPT" 2>/dev/null | tr -d ' ')"
[ -n "$SIZE" ] || exit 0
[ "$SIZE" -ge 2000 ] 2>/dev/null || exit 0

SLUG="$(om_slug "$CWD")"
[ -n "$SLUG" ] || SLUG="unknown"

NOW_STAMP="$(date -u +%Y-%m-%d-%H%M%S)"
NOW_DATE="${NOW_STAMP%-*}"
NOW_TIME="${NOW_STAMP##*-}"
NOW_TIME="${NOW_TIME:0:2}:${NOW_TIME:2:2}:${NOW_TIME:4:2}"

OUT_DIR="$VAULT/claude-memory/sessions/$SLUG"
mkdir -p "$OUT_DIR" 2>/dev/null || exit 0
OUT_FILE="$OUT_DIR/${NOW_STAMP}.md"

# Extract user+assistant messages. Handles both content-array and string-body
# shapes the transcript JSONL uses. Cap at ~200 KB.
CONVO="$(
  jq -r '
    . as $entry
    | select($entry.type == "user" or $entry.type == "assistant")
    | $entry.message as $m
    | (if ($m.content | type) == "array" then
        ($m.content
          | map(
              if .type == "text" then .text
              elif .type == "tool_use" then "[tool_use: \(.name // "?")]"
              elif .type == "tool_result" then (.content | tostring)
              else empty
              end
            )
          | join("\n"))
      elif ($m.content | type) == "string" then $m.content
      else empty
      end) as $body
    | select($body | length > 0)
    | "[\($entry.type | ascii_upcase)]\n\($body)\n"
  ' "$TRANSCRIPT" 2>/dev/null | head -c 204800
)"
[ -n "$CONVO" ] || exit 0

TEMPLATE_PATH="$(om_resolve_distill_template "$SLUG")"
TMPL_RAW="$(cat "$TEMPLATE_PATH")"

SPLIT="$(om_split_frontmatter "$TMPL_RAW"; printf x)"
SPLIT="${SPLIT%x}"
FM_RAW="${SPLIT%%$'\x1e'*}"
BODY_RAW="${SPLIT#*$'\x1e'}"

FM_OUT="$(om_render "$FM_RAW")"
PROMPT="$(om_render "$BODY_RAW")"

# CLAUDECODE="" avoids the "Cannot be launched inside another Claude Code session" guard.
NOTE_BODY="$(CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null)"

{
  if [ -n "$FM_OUT" ]; then
    # Strip trailing newlines so the emitted "\n\n" produces exactly one blank
    # line between the frontmatter and the body (AC5).
    while [ "${FM_OUT: -1}" = $'\n' ]; do
      FM_OUT="${FM_OUT%$'\n'}"
    done
    printf '%s\n\n' "$FM_OUT"
  else
    printf -- '---\n'
    printf 'date: %s\n' "$NOW_DATE"
    printf 'time: %s\n' "$NOW_TIME"
    printf 'session_id: %s\n' "$SESSION_ID"
    printf 'project: %s\n' "$SLUG"
    printf 'cwd: %s\n' "$CWD"
    printf 'end_reason: %s\n' "$REASON"
    printf 'source: claude-code\n'
    printf -- '---\n\n'
  fi
  if [ -n "$NOTE_BODY" ]; then
    printf '%s\n' "$NOTE_BODY"
  else
    # shellcheck disable=SC2016
    printf '## Summary\n\nDistillation returned no content. See transcript: `%s`\n' "$TRANSCRIPT"
  fi
} > "$OUT_FILE" 2>/dev/null || exit 0

INDEX="$VAULT/claude-memory/Index.md"
REL_NOTE="sessions/$SLUG/${NOW_STAMP}.md"
LINK_LINE="- [[${REL_NOTE}]] — ${SLUG} (${NOW_DATE} ${NOW_TIME} UTC)"

if [ ! -f "$INDEX" ]; then
  {
    printf '# Claude Memory Index\n\n'
    printf 'Auto-generated session notes from the obsidian-memory plugin.\n\n'
    printf '## Sessions\n\n'
    printf '%s\n' "$LINK_LINE"
  } > "$INDEX" 2>/dev/null || exit 0
else
  TMP="$(mktemp "${TMPDIR:-/tmp}/vault-index.XXXXXX")"
  if awk -v line="$LINK_LINE" '
    { print }
    !inserted && /^## Sessions[[:space:]]*$/ {
      print ""
      print line
      inserted = 1
    }
    END {
      if (!inserted) {
        print ""
        print "## Sessions"
        print ""
        print line
      }
    }
  ' "$INDEX" > "$TMP" 2>/dev/null; then
    mv "$TMP" "$INDEX" 2>/dev/null || rm -f "$TMP"
  else
    rm -f "$TMP"
  fi
fi

exit 0
