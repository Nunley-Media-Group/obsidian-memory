#!/usr/bin/env bash
# vault-rag.sh — UserPromptSubmit hook.
# Keyword-searches the user's Obsidian vault and emits a <vault-context> block
# on stdout, which Claude Code prepends to the model's context.
#
# Runs on every user prompt, so the scoring pass is a single rg/grep invocation
# rather than one subprocess per file.

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
om_load_config rag

PAYLOAD="$(om_read_payload)" || exit 0
PROMPT="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0

STOPWORDS="the|and|for|with|that|this|from|have|your|what|when|where|which|will|would|could|should|there|their|them|than|then|into|over|been|being|does|doing|about|just|like|some|only|also|make|made|used|using|file|code|test|user|tool|want|need|help|here|http|https|bash|echo|true|false|null|none|please|cannot|issue|task|line|lines"

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

REGEX="($(printf '%s' "$KEYWORDS" | paste -sd '|' -))"
KW_ATTR="$(printf '%s' "$KEYWORDS" | paste -sd ',' -)"

TMP_HITS="$(mktemp "${TMPDIR:-/tmp}/vault-rag.XXXXXX")"
trap 'rm -f "$TMP_HITS" 2>/dev/null; exit 0' EXIT

if command -v rg >/dev/null 2>&1; then
  HAVE_RG=1
else
  HAVE_RG=0
fi

# Single-pass scoring: one process walks the whole vault. rg/grep emit
# "path:count"; awk flips that to "count<TAB>path" for downstream sort/head.
# Splitting on the LAST ':' guards against paths that contain ':'.
if [ "$HAVE_RG" = 1 ]; then
  rg -c -i --no-messages \
      --glob '*.md' \
      --glob '!.obsidian/**' \
      --glob '!.trash/**' \
      -e "$REGEX" "$VAULT" 2>/dev/null \
    | awk 'BEGIN{OFS="\t"} { i=length($0); while (i>0 && substr($0,i,1)!=":") i--;
        if (i==0) next; n=substr($0,i+1); p=substr($0,1,i-1); if (n+0>0) print n, p }' \
    | sort -rn -k1,1 \
    > "$TMP_HITS"
else
  find "$VAULT" \
      \( -path "$VAULT/.obsidian" -o -path "$VAULT/.trash" \) -prune \
      -o -type f -name '*.md' -print0 2>/dev/null \
    | xargs -0 grep -c -i -H -E -e "$REGEX" 2>/dev/null \
    | awk 'BEGIN{OFS="\t"} { i=length($0); while (i>0 && substr($0,i,1)!=":") i--;
        if (i==0) next; n=substr($0,i+1); p=substr($0,1,i-1); if (n+0>0) print n, p }' \
    | sort -rn -k1,1 \
    > "$TMP_HITS"
fi

[ -s "$TMP_HITS" ] || exit 0

TOP="$(head -n 5 "$TMP_HITS")"
[ -n "$TOP" ] || exit 0

printf '<vault-context source="obsidian" keywords="%s">\n' "$KW_ATTR"

printf '%s\n' "$TOP" | while IFS=$'\t' read -r hits path; do
  rel="${path#"$VAULT"/}"
  printf '\n### %s  (hits: %s)\n' "$rel" "$hits"
  excerpt="$(grep -n -i -E -B 2 -A 8 -m 1 "$REGEX" "$path" 2>/dev/null | head -c 600)"
  if [ -n "$excerpt" ]; then
    # shellcheck disable=SC2016
    printf '```\n%s\n```\n' "$excerpt"
  fi
done

printf '</vault-context>\n'
exit 0
