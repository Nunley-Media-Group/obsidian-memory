#!/usr/bin/env bats

setup() {
  load '../helpers/scratch'
  cd "$PLUGIN_ROOT"
}

teardown() {
  assert_home_untouched
}

@test "gate: shellcheck passes on scripts/ and tests/" {
  run bash -c 'shellcheck scripts/*.sh tests/**/*.sh 2>/dev/null || shellcheck $(find scripts tests -name "*.sh")'
  [ "$status" -eq 0 ]
}

@test "gate: bats unit exits 0" {
  run bats tests/unit
  [ "$status" -eq 0 ]
}

@test "gate: bats integration exits 0 (self-excluding this file)" {
  # Running bats tests/integration from inside an integration test would
  # recurse forever. Validate via presence of the directory + smoke file.
  [ -d "$PLUGIN_ROOT/tests/integration" ]
  [ -f "$PLUGIN_ROOT/tests/integration/smoke.bats" ]
  run bats tests/integration/smoke.bats
  [ "$status" -eq 0 ]
}

@test "gate: tests/run-bdd.sh exits 0 on a clean repo" {
  # Avoid recursion when this sweep fires from inside a run-bdd invocation.
  if [ "${OBM_IN_BDD_RUN:-0}" = 1 ]; then
    skip "nested run-bdd invocation — skipped to prevent recursion"
  fi
  run env OBM_IN_BDD_RUN=1 tests/run-bdd.sh
  [ "$status" -eq 0 ]
}

@test "gate: jq empty .claude-plugin/plugin.json hooks/hooks.json exits 0" {
  run jq empty .claude-plugin/plugin.json hooks/hooks.json
  [ "$status" -eq 0 ]
}

@test "drift: tech.md gate commands are byte-identical across harness files" {
  local tech="$PLUGIN_ROOT/steering/tech.md"
  local sweep="$PLUGIN_ROOT/tests/integration/gate_sweep.bats"
  local runner="$PLUGIN_ROOT/tests/run-bdd.sh"

  [ -f "$tech" ]
  [ -f "$sweep" ]
  [ -f "$runner" ]

  # Every canonical command string in the Verification Gates table appears in
  # gate_sweep.bats verbatim. The runner's own command ("tests/run-bdd.sh") is
  # the one reference that must exist in all three files.
  grep -qF 'shellcheck scripts/*.sh tests/**/*.sh' "$tech"
  grep -qF 'shellcheck scripts/*.sh tests/**/*.sh' "$sweep"

  grep -qF 'bats tests/unit' "$tech"
  grep -qF 'bats tests/unit' "$sweep"

  grep -qF 'bats tests/integration' "$tech"
  grep -qF 'bats tests/integration' "$sweep"

  grep -qF 'tests/run-bdd.sh' "$tech"
  grep -qF 'tests/run-bdd.sh' "$sweep"

  grep -qF 'jq empty .claude-plugin/plugin.json hooks/hooks.json' "$tech"
  grep -qF 'jq empty .claude-plugin/plugin.json hooks/hooks.json' "$sweep"
}
