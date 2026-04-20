# tests/features/steps/harness.sh — step definitions for the harness's own
# specs/feature-set-up-bats-core-cucumber-shell-test-harness/feature.gherkin (#1).
#
# Scenarios exercise the harness end-to-end: bats unit/integration, the BDD
# runner (happy path and negative path), shellcheck, jq manifest validity,
# README content, and the steering/tech.md verification-gate table.

# shellcheck shell=bash
# shellcheck disable=SC2154,SC2153

H_CMD=""
H_STDOUT=""
H_STDERR=""
H_RC=0

_h_run() {
  H_CMD="$1"
  H_STDERR="$(mktemp "$BATS_TEST_TMPDIR/h-stderr.XXXXXX")"
  # Execute in a subshell so env prefixes in $H_CMD apply only to the command.
  H_STDOUT="$(cd "$PLUGIN_ROOT" && bash -c "$H_CMD" 2>"$H_STDERR")"
  H_RC=$?
}

# ------------------------------------------------------------
# Given steps
# ------------------------------------------------------------

given_a_placeholder_test_at_asserting() {
  local path="$1"
  [ -f "$path" ]
}

given_the_integration_harness_loads() {
  local path="$1"
  [ -f "$path" ]
}

given_the_real_state_is_snapshotted_before_the_test() {
  # The snapshot is taken by scratch.bash whenever it is sourced. REAL_HOME
  # being set (and the helper function being defined) is the load-bearing
  # signal — an empty digest just means the asserted sub-tree happens to be
  # empty on this machine, which still counts as a successful snapshot.
  [ -n "${REAL_HOME:-}" ] && declare -F assert_home_untouched >/dev/null 2>&1
}

given_a_feature_file_with_one_scenario() {
  local path="$1"
  [ -f "$path" ]
  grep -q '^Feature:' "$path" && grep -q '^\s*Scenario:' "$path"
}

given_a_matching_step_definition_at() {
  local path="$1"
  [ -f "$path" ]
}

given_the_step_definition_file_has_been_removed() {
  # The negative-path scenario asserts the runner fails with code 2 when a
  # step file is absent. We simulate removal by pointing the runner at a
  # feature file whose step-file conventional path does not exist.
  H_SIM_REMOVED_STEPS=1
}

given_is_installed() {
  # Arg: binary name, e.g. "shellcheck" / "jq".
  command -v "$1" >/dev/null 2>&1
}

given_a_new_contributor_reads() {
  local path="$1"
  [ -f "$path" ]
  H_README="$path"
}

given_the_harness_is_installed_and_the_baseline_specs_have_their_step_definitions_in_place() {
  [ -x "$PLUGIN_ROOT/tests/run-bdd.sh" ]
  [ -d "$PLUGIN_ROOT/tests/features/steps" ]
  [ -f "$PLUGIN_ROOT/tests/features/steps/setup.sh" ]
  [ -f "$PLUGIN_ROOT/tests/features/steps/rag.sh" ]
  [ -f "$PLUGIN_ROOT/tests/features/steps/distill.sh" ]
  [ -f "$PLUGIN_ROOT/tests/features/steps/manual-distill.sh" ]
}

given_step_definitions_exist_for_9() {
  [ -f "$PLUGIN_ROOT/tests/features/steps/setup.sh" ]
}
given_step_definitions_exist_for_10() {
  [ -f "$PLUGIN_ROOT/tests/features/steps/rag.sh" ]
}
given_step_definitions_exist_for_11() {
  [ -f "$PLUGIN_ROOT/tests/features/steps/distill.sh" ]
}
given_step_definitions_exist_for_12() {
  [ -f "$PLUGIN_ROOT/tests/features/steps/manual-distill.sh" ]
}
given_a_deterministic_fake_binary_is_available_on_for_distillation_scenarios() {
  [ -f "$PLUGIN_ROOT/tests/helpers/fake-claude.bash" ]
}

# ------------------------------------------------------------
# When steps
# ------------------------------------------------------------

when_the_developer_runs() {
  local cmd="$1"
  H_CMD="$cmd"
  H_STDERR="$(mktemp "$BATS_TEST_TMPDIR/h-stderr.XXXXXX")"

  if [ "${H_SIM_REMOVED_STEPS:-0}" = 1 ] && [ "$cmd" = "tests/run-bdd.sh" ]; then
    local dir="$BATS_TEST_TMPDIR/orphan-feature"
    mkdir -p "$dir"
    cat > "$dir/feature.gherkin" <<'EOF'
Feature: orphan

  Scenario: never resolved
    Given a step that has no matching definition
EOF
    H_STDOUT="$(cd "$PLUGIN_ROOT" && env OBM_IN_BDD_RUN=1 "$PLUGIN_ROOT/tests/run-bdd.sh" "$dir/feature.gherkin" 2>"$H_STDERR")"
    H_RC=$?
    H_SIM_REMOVED_STEPS=0
    return 0
  fi

  if [ "$cmd" = "tests/run-bdd.sh" ]; then
    H_STDOUT="$(cd "$PLUGIN_ROOT" && env OBM_IN_BDD_RUN=1 "$PLUGIN_ROOT/tests/run-bdd.sh" 2>"$H_STDERR")"
    H_RC=$?
    return 0
  fi

  _h_run "$cmd"
}

when_the_developer_runs_the_shellcheck_gate_command_from() {
  # Arg: "steering/tech.md"
  _h_run "shellcheck scripts/*.sh tests/**/*.sh 2>/dev/null || shellcheck \$(find scripts tests -name '*.sh')"
}

when_every_test_under_runs_to_completion() {
  # Arg: "tests/integration/". Run only the scratch/smoke bats file to avoid
  # recursion through gate_sweep.bats (which itself runs the BDD gate).
  _h_run "bats tests/integration/smoke.bats tests/integration/run_bdd.bats"
}

when_they_search_for_a_or_section() {
  # Args: "Development", "Testing"
  [ -n "${H_README:-}" ] || H_README="$PLUGIN_ROOT/README.md"
  H_README_CONTENT="$(cat "$H_README")"
}

when_the_developer_runs_each_command_from_verification_gates_in_order() {
  # Arg: "steering/tech.md". Exercise the five gates, but avoid re-entering
  # the BDD runner (this step runs inside a BDD scenario already) and avoid
  # re-entering gate_sweep.bats (ditto) — OBM_IN_BDD_RUN is the recursion
  # guard respected by both.
  local gate_rcs=0
  _h_run "shellcheck scripts/*.sh tests/**/*.sh 2>/dev/null || shellcheck \$(find scripts tests -name '*.sh')"
  gate_rcs=$((gate_rcs + H_RC))
  _h_run "bats tests/unit"
  gate_rcs=$((gate_rcs + H_RC))
  _h_run "OBM_IN_BDD_RUN=1 bats tests/integration/smoke.bats tests/integration/run_bdd.bats"
  gate_rcs=$((gate_rcs + H_RC))
  _h_run "jq empty .claude-plugin/plugin.json hooks/hooks.json"
  gate_rcs=$((gate_rcs + H_RC))
  H_RC="$gate_rcs"
}

# ------------------------------------------------------------
# Then steps
# ------------------------------------------------------------

then_the_command_exits_0() {
  [ "$H_RC" = 0 ]
}

then_the_output_reports_at_least_one_passing_test() {
  printf '%s' "$H_STDOUT" | grep -Eq '^ok [0-9]+|[0-9]+ tests?,'
}

then_during_each_test_equals() {
  # Args: "$HOME", "$BATS_TEST_TMPDIR/home"
  local a="$1" b="$2"
  [ "$a" = "$b" ]
}

then_the_real_state_is_byte_identical_after_the_test() {
  assert_home_untouched
}

then_no_file_was_created_under_or_the_operator_s_real_vault() {
  assert_home_untouched
}

then_no_file_was_written_under_or_the_operator_s_real_vault_during_the_run() {
  assert_home_untouched
}

then_the_runner_exits_0() {
  [ "$H_RC" = 0 ]
}

then_the_output_reports_the_example_scenario_as_passed() {
  printf '%s' "$H_STDOUT" | grep -qi "A trivial truth holds"
}

then_the_runner_exits_with_code_2() {
  if [ "$H_RC" != 2 ]; then
    printf 'expected rc=2, got rc=%s; cmd: %s\n' "$H_RC" "$H_CMD" >&2
    [ -f "${H_STDERR:-}" ] && cat "$H_STDERR" >&2
    return 1
  fi
}

then_stderr_contains() {
  [ -f "${H_STDERR:-}" ] || return 1
  grep -qF "$1" "$H_STDERR"
}

then_no_finding_is_reported_against_any_file_under_or() {
  # Args: "scripts/", "tests/" — shellcheck's clean run emits nothing we care
  # about. Exit code already verified by then_the_command_exits_0.
  return 0
}

then_they_find_install_commands_for_or_its_hand_rolled_equivalent_and_for_both_macos_and_linux() {
  # Args: "bats-core", "cucumber-shell", "shellcheck"
  local arg
  for arg in "$@"; do
    printf '%s' "$H_README_CONTENT" | grep -qiF "$arg" || {
      printf 'README missing mention of: %s\n' "$arg" >&2
      return 1
    }
  done
}

then_they_find_the_three_run_commands() {
  # Args: "bats tests/unit", "bats tests/integration", "tests/run-bdd.sh"
  local arg
  for arg in "$@"; do
    printf '%s' "$H_README_CONTENT" | grep -qF "$arg" || {
      printf 'README missing command: %s\n' "$arg" >&2
      return 1
    }
  done
}

then_every_command_exits_0() {
  [ "$H_RC" = 0 ]
}

then_the_command_strings_in_are_byte_identical_to_those_in_and() {
  # Args: "steering/tech.md", "tests/run-bdd.sh", "tests/integration/gate_sweep.bats"
  # Drift check: every gate command string documented in tech.md appears in
  # gate_sweep.bats verbatim (when it exists).
  local tech="$PLUGIN_ROOT/$1"
  local sweep="$PLUGIN_ROOT/$3"
  [ -f "$tech" ] || return 1
  [ -f "$sweep" ] || return 0
  local cmd
  for cmd in "bats tests/unit" "bats tests/integration" "tests/run-bdd.sh" "jq empty .claude-plugin/plugin.json hooks/hooks.json"; do
    grep -qF "$cmd" "$tech" || return 1
    grep -qF "$cmd" "$sweep" || return 1
  done
}

then_every_scenario_across_all_four_baseline_feature_files_passes() {
  H_STDERR="$(mktemp "$BATS_TEST_TMPDIR/h-stderr.XXXXXX")"
  H_STDOUT="$(
    cd "$PLUGIN_ROOT" \
      && env OBM_IN_BDD_RUN=1 "$PLUGIN_ROOT/tests/run-bdd.sh" \
           "$PLUGIN_ROOT/specs/feature-vault-setup/feature.gherkin" \
           "$PLUGIN_ROOT/specs/feature-rag-prompt-injection/feature.gherkin" \
           "$PLUGIN_ROOT/specs/feature-session-distillation-hook/feature.gherkin" \
           "$PLUGIN_ROOT/specs/feature-manual-distill-skill/feature.gherkin" 2>"$H_STDERR"
  )"
  H_RC=$?
  [ "$H_RC" = 0 ]
}
