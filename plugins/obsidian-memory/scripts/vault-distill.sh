#!/usr/bin/env bash
# vault-distill.sh — SessionEnd hook.
# Reads the just-ended session's transcript, calls `claude -p` to produce a
# concise Obsidian note, and writes it under
# <vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md.
#
# Must fail silently (exit 0) on any missing dep, missing config, disabled
# flag, or empty input.

set -u
trap 'exit 0' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
[ -r "$CONFIG" ] || exit 0

VAULT="$(jq -r '.vaultPath // empty' "$CONFIG" 2>/dev/null)"
ENABLED="$(jq -r '(.distill.enabled != false)' "$CONFIG" 2>/dev/null)"
[ -n "$VAULT" ] || exit 0
[ -d "$VAULT" ] || exit 0
[ "$ENABLED" = "true" ] || exit 0

PAYLOAD="$(cat)"
[ -n "$PAYLOAD" ] || exit 0

TRANSCRIPT="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
REASON="$(printf '%s' "$PAYLOAD" | jq -r '.reason // "unknown"' 2>/dev/null)"

[ -n "$TRANSCRIPT" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0
[ -n "$CWD" ] || CWD="$(pwd)"

# Skip trivial sessions.
SIZE="$(wc -c <"$TRANSCRIPT" 2>/dev/null | tr -d ' ')"
[ -n "$SIZE" ] || exit 0
[ "$SIZE" -ge 2000 ] 2>/dev/null || exit 0

# Derive project slug.
SLUG="$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
[ -n "$SLUG" ] || SLUG="unknown"

# Extract user+assistant messages from JSONL, handling both content-array and
# string-body shapes. Cap at ~200 KB.
CONVO="$(
  jq -r '
    select(.type == "user" or .type == "assistant")
    | .message as $m
    | if ($m.content | type) == "array" then
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
      end
    | select(length > 0)
    | "[\(.type | ascii_upcase)]\n\(.)\n"
  ' "$TRANSCRIPT" 2>/dev/null | head -c 204800
)"
[ -n "$CONVO" ] || exit 0

PROMPT="You are distilling a Claude Code session transcript into a concise Obsidian note.

Output ONLY the note body in Markdown. No preamble. No outer code fences.

Include these sections (omit any that would be empty):

## Summary
Two or three sentences describing what the session accomplished.

## Decisions
Notable choices and the reasoning behind them.

## Patterns & Gotchas
Specific file paths, commands, identifiers, or non-obvious constraints worth remembering.

## Open Threads
What is unfinished or should be picked up next.

## Tags
A single space-separated line starting with #project/${SLUG}, plus 3–5 topical tags.

Use Obsidian [[wiki-links]] for salient entities (files, functions, concepts). Cap the note at ~500 words.

TRANSCRIPT:

${CONVO}"

NOTE_BODY="$(CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null)"

NOW_DATE="$(date -u +%Y-%m-%d)"
NOW_TIME="$(date -u +%H:%M:%S)"
NOW_STAMP="$(date -u +%Y-%m-%d-%H%M%S)"

OUT_DIR="$VAULT/claude-memory/sessions/$SLUG"
mkdir -p "$OUT_DIR" 2>/dev/null || exit 0
OUT_FILE="$OUT_DIR/${NOW_STAMP}.md"

{
  printf -- '---\n'
  printf 'date: %s\n' "$NOW_DATE"
  printf 'time: %s\n' "$NOW_TIME"
  printf 'session_id: %s\n' "${SESSION_ID:-unknown}"
  printf 'project: %s\n' "$SLUG"
  printf 'cwd: %s\n' "$CWD"
  printf 'end_reason: %s\n' "$REASON"
  printf 'source: claude-code\n'
  printf -- '---\n\n'
  if [ -n "$NOTE_BODY" ]; then
    printf '%s\n' "$NOTE_BODY"
  else
    printf '## Summary\n\nDistillation returned no content. See transcript: `%s`\n' "$TRANSCRIPT"
  fi
} > "$OUT_FILE" 2>/dev/null || exit 0

# Append to Index.md, newest-first under ## Sessions.
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
  # Insert the new line immediately after the "## Sessions" header.
  TMP="$(mktemp -t vault-index.XXXXXX)"
  awk -v line="$LINK_LINE" '
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
  ' "$INDEX" > "$TMP" 2>/dev/null && mv "$TMP" "$INDEX" 2>/dev/null || rm -f "$TMP"
fi

exit 0
