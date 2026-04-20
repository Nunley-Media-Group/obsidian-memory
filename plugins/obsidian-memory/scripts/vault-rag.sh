#!/usr/bin/env bash
# vault-rag.sh — UserPromptSubmit hook.
# Keyword-searches the user's Obsidian vault and emits a <vault-context> block
# on stdout, which Claude Code prepends to the model's context.
#
# Must fail silently (exit 0) on any missing dep, missing config, disabled
# flag, or empty input — a broken hook must never block the user.

set -u
# Never let a pipeline failure bubble up and block the user.
trap 'exit 0' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

# Hard deps: jq. Everything else is best-effort.
command -v jq >/dev/null 2>&1 || exit 0
[ -r "$CONFIG" ] || exit 0

VAULT="$(jq -r '.vaultPath // empty' "$CONFIG" 2>/dev/null)"
ENABLED="$(jq -r '(.rag.enabled != false)' "$CONFIG" 2>/dev/null)"
[ -n "$VAULT" ] || exit 0
[ -d "$VAULT" ] || exit 0
[ "$ENABLED" = "true" ] || exit 0

# Read payload from stdin.
PAYLOAD="$(cat)"
[ -n "$PAYLOAD" ] || exit 0

PROMPT="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0

STOPWORDS="the|and|for|with|that|this|from|have|your|what|when|where|which|will|would|could|should|there|their|them|than|then|into|over|been|being|does|doing|about|just|like|some|only|also|make|made|used|using|file|code|test|user|tool|want|need|help|here|http|https|bash|echo|true|false|null|none|please|cannot|issue|task|task|line|lines"

# Tokenize: lowercase, split on non-alphanumerics, drop stopwords, dedupe,
# keep words >=4 chars, cap at 6 keywords.
KEYWORDS="$(
  printf '%s' "$PROMPT" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk -v sw="$STOPWORDS" 'BEGIN{n=split(sw,a,"|"); for(i=1;i<=n;i++) s[a[i]]=1}
        length($0) >= 4 && !s[$0] && !seen[$0]++ { print; count++; if (count==6) exit }'
)"
[ -n "$KEYWORDS" ] || exit 0

# Build alternation regex.
REGEX="$(printf '%s' "$KEYWORDS" | paste -sd '|' -)"
[ -n "$REGEX" ] || exit 0
REGEX="($REGEX)"
KW_ATTR="$(printf '%s' "$KEYWORDS" | paste -sd ',' -)"

# Collect candidate .md files, excluding the auto-memory feedback dirs.
TMP_FILES="$(mktemp -t vault-rag.XXXXXX)"
trap 'rm -f "$TMP_FILES" "$TMP_FILES.hits" 2>/dev/null; exit 0' EXIT

if command -v rg >/dev/null 2>&1; then
  rg --no-messages --files "$VAULT" \
      --glob '*.md' \
      --glob '!claude-memory/projects/**' \
      --glob '!.obsidian/**' \
      --glob '!.trash/**' \
      > "$TMP_FILES" 2>/dev/null || true
else
  # POSIX fallback.
  find "$VAULT" \
      \( -path "$VAULT/claude-memory/projects" -o -path "$VAULT/.obsidian" -o -path "$VAULT/.trash" \) -prune \
      -o -type f -name '*.md' -print \
      > "$TMP_FILES" 2>/dev/null || true
fi

[ -s "$TMP_FILES" ] || exit 0

# Score each file by total hit count.
: > "$TMP_FILES.hits"
while IFS= read -r f; do
  [ -r "$f" ] || continue
  if command -v rg >/dev/null 2>&1; then
    hits="$(rg -c -i -o -e "$REGEX" "$f" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
  else
    hits="$(grep -c -i -E "$REGEX" "$f" 2>/dev/null || echo 0)"
  fi
  [ -n "$hits" ] || hits=0
  if [ "$hits" -gt 0 ] 2>/dev/null; then
    printf '%s\t%s\n' "$hits" "$f" >> "$TMP_FILES.hits"
  fi
done < "$TMP_FILES"

[ -s "$TMP_FILES.hits" ] || exit 0

# Top 5 by hit count.
TOP="$(sort -rn -k1,1 "$TMP_FILES.hits" | head -n 5)"
[ -n "$TOP" ] || exit 0

# Emit the context block.
printf '<vault-context source="obsidian" keywords="%s">\n' "$KW_ATTR"

printf '%s\n' "$TOP" | while IFS=$'\t' read -r hits path; do
  rel="${path#$VAULT/}"
  printf '\n### %s  (hits: %s)\n' "$rel" "$hits"
  # First match with 2 lines before / 8 after, capped at ~600 bytes.
  excerpt="$(grep -n -i -E -B 2 -A 8 -m 1 "$REGEX" "$path" 2>/dev/null | head -c 600)"
  if [ -n "$excerpt" ]; then
    printf '```\n%s\n```\n' "$excerpt"
  fi
done

printf '</vault-context>\n'
exit 0
