#!/usr/bin/env bats

# tests/integration/vault-rag-perf.bats — performance benchmark for the
# UserPromptSubmit hook. Validates the <300 ms p95 wall-time NFR from
# specs/feature-rag-prompt-injection/requirements.md on a synthetic
# 1,000-note vault.
#
# Skip via OBM_SKIP_PERF=1 on slow CI runners or dev machines where the
# `rg` fast-path is unavailable.

setup() {
  # Load before the skip check so teardown's assert_home_untouched is defined
  # on the skipped path — bats runs teardown regardless of skip.
  load '../helpers/scratch'

  if [ "${OBM_SKIP_PERF:-0}" = 1 ]; then
    skip "OBM_SKIP_PERF=1 set"
  fi

  RAG="$PLUGIN_ROOT/scripts/vault-rag.sh"
  CONFIG="$HOME/.claude/obsidian-memory/config.json"
  export RAG CONFIG

  mkdir -p "$HOME/.claude/obsidian-memory" "$HOME/.claude/projects"
  mkdir -p "$VAULT/claude-memory/sessions"
  ln -sfn "$HOME/.claude/projects" "$VAULT/claude-memory/projects"

  if date +%s%N 2>/dev/null | grep -qE '^[0-9]{13,}$'; then
    HAS_GNU_DATE=1
  else
    HAS_GNU_DATE=0
  fi
  export HAS_GNU_DATE

  cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "rag": { "enabled": true },
  "distill": { "enabled": true }
}
EOF
}

teardown() { assert_home_untouched; }

_seed_1000_notes() {
  # Deterministic fixture: 1000 notes each ~1 KB with a rotating
  # 20-word vocabulary so ~1/20 of the notes match any given prompt
  # keyword — realistic recall pressure for the scorer.
  local words=(alpha bravo charlie delta eecho foxtrot golfo hotel india juliet \
               kilotango limat mikes november oscar papayas quebec romeos sierra tangos)
  local i wi line
  for i in {1..1000}; do
    wi=$(( i % 20 ))
    line="${words[$wi]} is the topic of note number $i here"
    {
      printf '%s\n' "$line"
      printf '%s\n' "$line"
      printf '%s\n' "$line"
      printf '%s padding line for slightly larger notes\n' "${words[$(( (wi + 3) % 20 ))]}"
      printf '%s padding line for slightly larger notes\n' "${words[$(( (wi + 7) % 20 ))]}"
    } > "$VAULT/note-$(printf '%04d' "$i").md"
  done
}

_elapsed_ms() {
  # Falls back to python3 time.perf_counter when GNU date %s%N is unavailable
  # (HAS_GNU_DATE cached once in setup to avoid per-call subprocess overhead).
  local prompt="$1"
  local payload
  payload="$(jq -n --arg p "$prompt" '{prompt:$p}')"

  if [ "${HAS_GNU_DATE:-0}" = 1 ]; then
    local start end
    start="$(date +%s%N)"
    printf '%s' "$payload" | "$RAG" >/dev/null
    end="$(date +%s%N)"
    printf '%d\n' $(( (end - start) / 1000000 ))
    return 0
  fi

  python3 - "$RAG" <<'PY' "$payload"
import subprocess, sys, time
rag, payload = sys.argv[1], sys.argv[2]
t0 = time.perf_counter()
subprocess.run([rag], input=payload.encode(), stdout=subprocess.DEVNULL, check=False)
t1 = time.perf_counter()
print(int((t1 - t0) * 1000))
PY
}

@test "perf: p95 hook wall time < 300ms on a 1000-note vault" {
  _seed_1000_notes

  local prompts=(
    "alpha something useful"
    "bravo details about the topic"
    "charlie related content search"
    "delta follow-up inquiry"
    "eecho contextual request"
    "foxtrot historical reference"
    "golfo ancillary query"
    "hotel cross-reference check"
    "india descriptive search"
    "juliet lookup attempt"
    "kilotango background context"
    "limat tangential query"
    "mikes recurring topic"
    "november supplementary info"
    "oscar expanded context"
    "papayas latest notes"
    "quebec related work"
    "romeos prior discussion"
    "sierra design notes"
    "tangos implementation detail"
  )

  local ms times=()
  local p
  for p in "${prompts[@]}"; do
    ms="$(_elapsed_ms "$p")"
    times+=("$ms")
  done

  local sorted p95 p95_idx
  sorted="$(printf '%s\n' "${times[@]}" | sort -n)"
  # Ceiling of N * 0.95 — 19th of 20 samples, 10th of 10, etc.
  p95_idx=$(( (${#times[@]} * 95 + 99) / 100 ))
  p95="$(printf '%s\n' "$sorted" | sed -n "${p95_idx}p")"

  printf 'vault-rag p95 over %d samples: %s ms\n' "${#times[@]}" "$p95" >&3
  printf 'samples (sorted asc): %s\n' "$(printf '%s\n' "$sorted" | tr '\n' ' ')" >&3

  [ "$p95" -lt 300 ]
}
