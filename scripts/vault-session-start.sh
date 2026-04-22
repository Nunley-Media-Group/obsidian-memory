#!/usr/bin/env bash
# vault-session-start.sh — SessionStart hook.
#
# Captures a one-line policy snapshot for this session_id so that a
# mid-session `/obsidian-memory:scope` edit cannot retroactively kill an
# in-flight distillation at SessionEnd. Never blocks the user: every
# terminating path exits 0, and the ERR trap enforces the invariant.
#
# Snapshot file:
#   ~/.claude/obsidian-memory/session-policy/<session_id>.state
# Single-line contents are one of:  all | excluded | allowlist-hit | allowlist-miss

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

# We deliberately do NOT call om_load_config here — snapshots are taken
# regardless of rag/distill's individual enable flags so a toggle-on mid-way
# through a session still finds a usable snapshot at SessionEnd.

PAYLOAD="$(om_read_payload)" || exit 0

IFS=$'\t' read -r SESSION_ID CWD < <(
  printf '%s' "$PAYLOAD" | jq -r '[.session_id // "", .cwd // ""] | @tsv' 2>/dev/null
)

[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"

POLICY_DIR="${HOME}/.claude/obsidian-memory/session-policy"
mkdir -p "$POLICY_DIR" 2>/dev/null || exit 0

STATE="$(om_policy_state "$CWD")"
printf '%s\n' "$STATE" > "$POLICY_DIR/${SESSION_ID}.state" 2>/dev/null || exit 0

exit 0
