#!/usr/bin/env bash
# vault-distill.sh — SessionEnd hook.
# Reads the just-ended session's transcript, calls `claude -p` to produce a
# concise Obsidian note, and writes it under
# <vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md.
#
# Architecture (post-fix #25):
#   Sync head  (everything before the worker launch): fast path — parse, scope
#              gate, size floor, slug, prompt render. Returns exit 0 quickly so
#              /clear's SessionEnd grace period is never exceeded.
#   Worker     (written to a temp file and launched detached): claude -p
#              invocation, note assembly, file write, Index.md update. Launched
#              detached via setsid/nohup/disown so it survives hook teardown.

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
om_load_config distill

# Re-entrancy guard: if this invocation is itself running inside a recursive
# claude -p SessionEnd (i.e., we are the worker's own nested hook), bail out
# immediately. Two checks:
#   1. OM_DISTILL_WORKER_ACTIVE=1 — set in the worker's env before spawning
#      the nested claude -p, so any SessionEnd re-entry from that subprocess
#      sees this marker and short-circuits.
#   2. CLAUDECODE unset/empty — the worker clears it before calling claude -p.
#      When CLAUDECODE is non-empty we are the outer (real) hook invocation; when
#      it is empty AND OM_DISTILL_WORKER_ACTIVE is set we know we are the inner.
if [ "${OM_DISTILL_WORKER_ACTIVE:-}" = "1" ] && [ -z "${CLAUDECODE:-}" ]; then
  exit 0
fi

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

# ---------------------------------------------------------------------------
# Sync-head debug helper.
# ---------------------------------------------------------------------------

DEBUG_LOG="${HOME}/.claude/obsidian-memory/distill-debug.log"

_log_debug() {
  local dir
  dir="$(dirname "$DEBUG_LOG")"
  [ -d "$dir" ] || return 0
  printf '[%s] %s\n' "$(date -u +%H:%M:%SZ 2>/dev/null || date +%H:%M:%S)" "$*" \
    >> "$DEBUG_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Worker script: write to a temp file then launch detached.
# All slow work lives here: claude -p, note assembly, file write, Index.md.
# Receives context exclusively via environment variables exported below.
# ---------------------------------------------------------------------------

# Export every variable the worker needs.
export VAULT SLUG NOW_STAMP NOW_DATE NOW_TIME OUT_DIR OUT_FILE
export TRANSCRIPT SESSION_ID CWD REASON
export CONVO FM_OUT PROMPT
export DEBUG_LOG

# Write the worker to a temp file — avoids bash 3.2 heredoc-in-$() issues.
# Pass the path via env so the worker can self-clean after completion.
OM_WORKER_FILE="$(mktemp "${TMPDIR:-/tmp}/om-worker.XXXXXX.sh")" || exit 0
export OM_WORKER_FILE

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -u'
  printf '%s\n' "trap 'exit 0' ERR"
} > "$OM_WORKER_FILE"
cat >> "$OM_WORKER_FILE" << 'WORKER_BODY'

_wlog() {
  local dir
  dir="$(dirname "$DEBUG_LOG")"
  [ -d "$dir" ] || return 0
  printf '[%s] %s\n' "$(date -u +%H:%M:%SZ 2>/dev/null || date +%H:%M:%S)" "$*" \
    >> "$DEBUG_LOG" 2>/dev/null || true
}

worker_pid="$$"

# Re-entrancy guard: if the nested claude -p fires its own SessionEnd and
# re-enters vault-distill.sh, that outer re-entry short-circuits before reaching
# here. This inner guard is an extra belt-and-suspenders check in case
# OM_DISTILL_WORKER_ACTIVE somehow leaked without CLAUDECODE being cleared.
if [ "${OM_DISTILL_WORKER_ACTIVE:-}" = "1" ] && [ -z "${CLAUDECODE:-}" ]; then
  _wlog "[worker pid=${worker_pid}] re-entrancy guard triggered; exiting"
  exit 0
fi

_wlog "[worker pid=${worker_pid}] start: OUT_FILE=${OUT_FILE:-<unset>}"

# CLAUDECODE="" avoids the "Cannot be launched inside another Claude Code
# session" guard. OM_DISTILL_WORKER_ACTIVE=1 lets any recursive re-entry
# (via the nested claude -p's own SessionEnd hook) short-circuit.
NOTE_BODY="$(OM_DISTILL_WORKER_ACTIVE=1 CLAUDECODE="" claude -p "${PROMPT}" 2>/dev/null)"
claude_rc=$?
_wlog "[worker pid=${worker_pid}] claude -p exit=${claude_rc}"

{
  if [ -n "${FM_OUT:-}" ]; then
    while [ "${FM_OUT: -1}" = $'\n' ]; do
      FM_OUT="${FM_OUT%$'\n'}"
    done
    printf '%s\n\n' "${FM_OUT}"
  else
    printf -- '---\n'
    printf 'date: %s\n' "${NOW_DATE}"
    printf 'time: %s\n' "${NOW_TIME}"
    printf 'session_id: %s\n' "${SESSION_ID}"
    printf 'project: %s\n' "${SLUG}"
    printf 'cwd: %s\n' "${CWD}"
    printf 'end_reason: %s\n' "${REASON}"
    printf 'source: claude-code\n'
    printf -- '---\n\n'
  fi
  if [ -n "${NOTE_BODY}" ]; then
    printf '%s\n' "${NOTE_BODY}"
  else
    printf '## Summary\n\nDistillation returned no content. See transcript: `%s`\n' "${TRANSCRIPT}"
  fi
} > "${OUT_FILE}" 2>/dev/null

if [ -f "${OUT_FILE}" ]; then
  nbytes="$(wc -c < "${OUT_FILE}" 2>/dev/null | tr -d ' ')"
  _wlog "[worker pid=${worker_pid}] wrote ${OUT_FILE} (${nbytes} bytes)"
else
  _wlog "[worker pid=${worker_pid}] write to ${OUT_FILE} failed"
  exit 0
fi

INDEX="${VAULT}/claude-memory/Index.md"
REL_NOTE="sessions/${SLUG}/${NOW_STAMP}.md"
LINK_LINE="- [[${REL_NOTE}]] — ${SLUG} (${NOW_DATE} ${NOW_TIME} UTC)"

if [ ! -f "${INDEX}" ]; then
  {
    printf '# Claude Memory Index\n\n'
    printf 'Auto-generated session notes from the obsidian-memory plugin.\n\n'
    printf '## Sessions\n\n'
    printf '%s\n' "${LINK_LINE}"
  } > "${INDEX}" 2>/dev/null || {
    _wlog "[worker pid=${worker_pid}] index create failed"
    exit 0
  }
else
  TMP="$(mktemp "${TMPDIR:-/tmp}/vault-index.XXXXXX")"
  if awk -v line="${LINK_LINE}" '
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
  ' "${INDEX}" > "${TMP}" 2>/dev/null; then
    mv "${TMP}" "${INDEX}" 2>/dev/null || rm -f "${TMP}"
  else
    rm -f "${TMP}"
    _wlog "[worker pid=${worker_pid}] index update failed"
    exit 0
  fi
fi

_wlog "[worker pid=${worker_pid}] index updated; done"
# Remove the worker temp file after completion.
rm -f "${OM_WORKER_FILE:-}" 2>/dev/null || true
exit 0
WORKER_BODY

# ---------------------------------------------------------------------------
# Sync head: launch the worker detached, log one confirmation line, exit 0.
# Prefer setsid -f (new session, survives SIGHUP), fall back to nohup ... &,
# then bare ( ... ) & disown.
# ---------------------------------------------------------------------------

if command -v setsid >/dev/null 2>&1; then
  # setsid -f: fork + new session; the parent returns immediately.
  # If -f is unsupported (older setsid), fall back to backgrounded setsid + disown.
  setsid -f bash "$OM_WORKER_FILE" </dev/null >/dev/null 2>/dev/null \
    || {
      setsid bash "$OM_WORKER_FILE" </dev/null >/dev/null 2>/dev/null &
      disown 2>/dev/null || true
    }
elif command -v nohup >/dev/null 2>&1; then
  nohup bash "$OM_WORKER_FILE" </dev/null >/dev/null 2>/dev/null &
  disown 2>/dev/null || true
else
  ( bash "$OM_WORKER_FILE" </dev/null >/dev/null 2>/dev/null ) &
  disown 2>/dev/null || true
fi

_log_debug "detached worker spawned; hook returning"
exit 0
