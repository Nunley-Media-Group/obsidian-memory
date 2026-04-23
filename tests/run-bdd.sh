#!/usr/bin/env bash
# tests/run-bdd.sh — shell-native Gherkin runner (cucumber-shell contract).
#
# Globs specs/*/feature.gherkin (or feature files from argv), parses each
# Feature/Background/Scenario/Given/When/Then/And line, resolves each step
# to a function defined under tests/features/steps/*.sh, and invokes it with
# the scenario's quoted literals as positional arguments.
#
# Supported Gherkin subset: Feature, Background, Scenario, Given/When/Then/And/But,
# quoted-literal arguments, '#' line comments. Unsupported features (Scenario Outline,
# DocStrings, DataTables) are silently ignored with a stderr warning.
#
# Exit codes:
#   0 — every scenario passed; every step resolved to a defined function
#   1 — ≥1 scenario failed an assertion (non-zero return from a step function)
#   2 — ≥1 step was undefined in any loaded step file
#   other — internal runner failure (missing specs dir, unreadable feature file)
#
# Never evaluates step text as a command. Step text is pattern-normalised to
# a function name; quoted literals are extracted and passed as argv.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STEPS_DIR="$SCRIPT_DIR/features/steps"
HELPERS_DIR="$SCRIPT_DIR/helpers"

_log_err() { printf '%s\n' "$*" >&2; }

_step_file_for() {
  # Map feature dir name to its conventional step file.
  local dir_name="$1"
  case "$dir_name" in
    feature-vault-setup)                              printf '%s' "$STEPS_DIR/setup.sh" ;;
    feature-rag-prompt-injection)                     printf '%s' "$STEPS_DIR/rag.sh" ;;
    feature-session-distillation-hook)                printf '%s' "$STEPS_DIR/distill.sh" ;;
    feature-manual-distill-skill)                     printf '%s' "$STEPS_DIR/manual-distill.sh" ;;
    feature-doctor-health-check-skill)                printf '%s' "$STEPS_DIR/doctor.sh" ;;
    feature-add-obsidian-memory-teardown-skill)       printf '%s' "$STEPS_DIR/teardown.sh" ;;
    feature-add-obsidian-memory-toggle-skill-for-rag-distill-enable-flags) \
                                                      printf '%s' "$STEPS_DIR/toggle.sh" ;;
    feature-add-per-project-overrides-exclude-scope-config) \
                                                      printf '%s' "$STEPS_DIR/vault-scope.sh" ;;
    feature-set-up-bats-core-cucumber-shell-test-harness) printf '%s' "$STEPS_DIR/harness.sh" ;;
    example)                                          printf '%s' "$STEPS_DIR/example.sh" ;;
    *)
      # Fallback: feature-<slug>.sh or bug-<slug>.sh or <slug>.sh
      local short="${dir_name#feature-}"
      short="${short#bug-}"
      if   [ -f "$STEPS_DIR/$short.sh" ]; then printf '%s' "$STEPS_DIR/$short.sh"
      elif [ -f "$STEPS_DIR/$dir_name.sh" ]; then printf '%s' "$STEPS_DIR/$dir_name.sh"
      else printf '%s' "$STEPS_DIR/$short.sh"
      fi
      ;;
  esac
}

_step_keyword() {
  # Echo the leading keyword (given|when|then) or the empty string.
  # And/But get resolved to the passed-in "last keyword" argument.
  local raw="$1" last="$2"
  local kw
  kw="$(printf '%s' "$raw" | sed -nE 's/^[[:space:]]*(Given|When|Then|And|But)[[:space:]].*/\1/p')"
  case "$kw" in
    Given) printf 'given' ;;
    When)  printf 'when' ;;
    Then)  printf 'then' ;;
    And|But) printf '%s' "$last" ;;
    *) printf '' ;;
  esac
}

_normalize_step() {
  # Keyword prefix + normalised step body. Function name convention:
  #   <keyword>_<step-body-with-quoted-literals-stripped>
  local body="$1" keyword="$2"
  local norm
  norm="$(
    printf '%s' "$body" \
      | sed -E 's/^[[:space:]]*(Given|When|Then|And|But)[[:space:]]+//' \
      | sed -E 's/"[^"]*"//g' \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9\n' '_' \
      | sed -E 's/_+/_/g; s/^_+//; s/_+$//'
  )"
  if [ -z "$norm" ]; then
    printf ''
  elif [ -n "$keyword" ]; then
    printf '%s_%s' "$keyword" "$norm"
  else
    printf '%s' "$norm"
  fi
}

_extract_literals() {
  # Emit each quoted literal on its own line, in order of appearance.
  printf '%s' "$1" | awk '
    {
      in_q = 0; buf = "";
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1);
        if (c == "\"") {
          if (in_q) { print buf; buf = ""; in_q = 0 }
          else       { in_q = 1 }
        } else if (in_q) {
          buf = buf c
        }
      }
    }
  '
}

_expand_vars() {
  # Expand $VAR and ${VAR} via indirect expansion. Unknown variables become
  # the empty string. No `eval`, no command substitution, no arithmetic —
  # only bare variable references in developer-authored Gherkin literals.
  local input="$1" out="" i=0 len n_len j c name
  len=${#input}
  while [ "$i" -lt "$len" ]; do
    c="${input:$i:1}"
    if [ "$c" = '$' ]; then
      j=$((i + 1))
      name=""
      if [ "$j" -lt "$len" ] && [ "${input:$j:1}" = '{' ]; then
        j=$((j + 1))
        while [ "$j" -lt "$len" ] && [ "${input:$j:1}" != '}' ]; do
          name="$name${input:$j:1}"
          j=$((j + 1))
        done
        [ "$j" -lt "$len" ] && [ "${input:$j:1}" = '}' ] && j=$((j + 1))
      else
        while [ "$j" -lt "$len" ]; do
          c="${input:$j:1}"
          case "$c" in
            [A-Za-z0-9_]) name="$name$c"; j=$((j + 1)) ;;
            *) break ;;
          esac
        done
      fi
      if [ -n "$name" ]; then
        n_len=${#name}
        if [ "$n_len" -gt 0 ]; then
          out="$out${!name-}"
          i=$j
          continue
        fi
      fi
    fi
    out="$out${input:$i:1}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

_run_scenario() {
  # One scenario, one subshell. Returns 0/1/2.
  # $2 = scenario name (accepted for callsite symmetry; logging happens in the
  # dispatcher so this arg is deliberately unused inside the subshell).
  local feature="$1" _scenario_name="$2" steps_file="$3" all_steps="$4"
  : "$_scenario_name"
  (
    set -u
    # Always give each scenario its own BATS_TEST_TMPDIR so nested invocations
    # (e.g., run-bdd.sh called from inside a bats test) don't share scratch
    # state with the parent or with sibling scenarios.
    BATS_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/obm-bdd.XXXXXX")"
    export BATS_TEST_TMPDIR
    # shellcheck disable=SC1091
    . "$HELPERS_DIR/scratch.bash"

    if [ -f "$STEPS_DIR/common.sh" ]; then
      # shellcheck disable=SC1090,SC1091
      . "$STEPS_DIR/common.sh"
    fi

    if [ -n "$steps_file" ] && [ -f "$steps_file" ]; then
      # shellcheck disable=SC1090
      . "$steps_file"
    fi

    local rc=0 raw pp fname args lit last_kw="" kw
    while IFS= read -r raw; do
      [ -z "$raw" ] && continue
      # Pre-process: encode \" as \x01 so quoted-literal parsers see balanced quotes.
      pp="$(printf '%s' "$raw" | sed 's/\\"/\x01/g')"
      kw="$(_step_keyword "$pp" "$last_kw")"
      [ -n "$kw" ] && last_kw="$kw"
      fname="$(_normalize_step "$pp" "$kw")"
      [ -z "$fname" ] && continue

      if ! declare -F "$fname" >/dev/null 2>&1; then
        _log_err "  undefined step: $raw"
        exit 2
      fi

      args=()
      while IFS= read -r lit; do
        [ -z "$lit" ] && continue
        # Decode \x01 back to ".
        lit="$(printf '%s' "$lit" | tr '\001' '"')"
        args+=("$(_expand_vars "$lit")")
      done < <(_extract_literals "$pp")

      if [ "${#args[@]}" -gt 0 ]; then
        if ! "$fname" "${args[@]}"; then
          _log_err "  FAILED step: $raw"
          rc=1
          break
        fi
      else
        if ! "$fname"; then
          _log_err "  FAILED step: $raw"
          rc=1
          break
        fi
      fi
    done <<< "$all_steps"

    exit "$rc"
  )
}

_run_feature() {
  local feature="$1"
  local dir_name steps_file
  dir_name="$(basename "$(dirname "$feature")")"
  steps_file="$(_step_file_for "$dir_name")"

  local bg_steps="" current_name="" current_steps=""
  local in_bg=0 have_scenario=0
  local trimmed line

  # _dispatch_scenario does not write to "$feature"; SC2094 is a false positive here.
  # shellcheck disable=SC2094
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$trimmed" in
      ''|'#'*)
        continue
        ;;
      Feature:*)
        continue
        ;;
      Background:*)
        in_bg=1
        continue
        ;;
      'Scenario Outline:'*|Examples:*)
        if [ "$have_scenario" = 1 ]; then
          _dispatch_scenario "$feature" "$current_name" "$steps_file" "$bg_steps" "$current_steps"
        fi
        _log_err "warning: Scenario Outline / Examples not supported in $feature; skipping"
        in_bg=0
        have_scenario=0
        current_name=""
        current_steps=""
        continue
        ;;
      Scenario:*)
        if [ "$have_scenario" = 1 ]; then
          _dispatch_scenario "$feature" "$current_name" "$steps_file" "$bg_steps" "$current_steps"
        fi
        in_bg=0
        have_scenario=1
        current_name="$(printf '%s' "$trimmed" | sed -E 's/^Scenario:[[:space:]]*//')"
        current_steps=""
        ;;
      Given*|When*|Then*|And*|But*)
        if [ "$in_bg" = 1 ]; then
          bg_steps="${bg_steps}${trimmed}"$'\n'
        elif [ "$have_scenario" = 1 ]; then
          current_steps="${current_steps}${trimmed}"$'\n'
        fi
        ;;
      *)
        # Feature description lines live here ("As a …", "I want …", "So that …").
        # Only meaningful inside the Feature block; ignore in every other context.
        :
        ;;
    esac
  done < "$feature"

  if [ "$have_scenario" = 1 ]; then
    _dispatch_scenario "$feature" "$current_name" "$steps_file" "$bg_steps" "$current_steps"
  fi
}

_dispatch_scenario() {
  local feature="$1" name="$2" steps_file="$3" bg="$4" body="$5"
  local rc all
  all="${bg}${body}"
  TOTAL=$((TOTAL + 1))
  printf '  Scenario: %s\n' "$name"
  _run_scenario "$feature" "$name" "$steps_file" "$all"
  rc=$?
  case "$rc" in
    0) PASSED=$((PASSED + 1)) ;;
    1) FAILED=$((FAILED + 1)); _log_err "    -> FAILED" ;;
    2) UNDEFINED=$((UNDEFINED + 1)); _log_err "    -> UNDEFINED STEP" ;;
    *) FAILED=$((FAILED + 1)); _log_err "    -> runner error rc=$rc" ;;
  esac
}

main() {
  local -a features=()
  if [ "$#" -gt 0 ]; then
    local arg
    for arg in "$@"; do
      if [ -f "$arg" ]; then
        features+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
      else
        _log_err "skip: feature not found: $arg"
      fi
    done
  else
    local glob
    shopt -s nullglob
    for glob in "$REPO_ROOT"/specs/*/feature.gherkin; do
      # Skip the harness's own feature on the default-glob path. Its scenarios
      # re-run the gate commands (bats integration, the BDD runner, the
      # linter, jq) that /verify-code already runs as direct gates — every
      # top-level BDD invocation would otherwise double the wall time of every
      # gate, and nested run-bdd.sh calls recurse through it. The
      # harness's BDD-runner self-tests live in tests/integration/run_bdd.bats
      # and tests/integration/gate_sweep.bats. To explicitly exercise the
      # harness feature, invoke tests/run-bdd.sh with its path as an argument.
      case "$glob" in *feature-set-up-bats-core-cucumber-shell-test-harness*) continue ;; esac
      features+=("$glob")
    done
    shopt -u nullglob
  fi

  if [ "${#features[@]}" -eq 0 ]; then
    _log_err "no feature files found"
    return 3
  fi

  TOTAL=0; PASSED=0; FAILED=0; UNDEFINED=0

  local f
  for f in "${features[@]}"; do
    printf 'Feature file: %s\n' "${f#"$REPO_ROOT"/}"
    _run_feature "$f"
  done

  printf '\n%d scenarios, %d passed, %d failed, %d undefined steps\n' \
    "$TOTAL" "$PASSED" "$FAILED" "$UNDEFINED"

  if [ "$UNDEFINED" -gt 0 ]; then
    return 2
  elif [ "$FAILED" -gt 0 ]; then
    return 1
  fi
  return 0
}

main "$@"
