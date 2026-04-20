#!/usr/bin/env bats

setup() {
  load '../helpers/scratch'
  TMP_SPECS="$BATS_TEST_TMPDIR/specs/example"
  mkdir -p "$TMP_SPECS"
  cp "$PLUGIN_ROOT/specs/example/feature.gherkin" "$TMP_SPECS/"
}

teardown() {
  assert_home_untouched
}

@test "BDD runner exits 0 when the example feature's step file is present" {
  run "$PLUGIN_ROOT/tests/run-bdd.sh" "$PLUGIN_ROOT/specs/example/feature.gherkin"
  [ "$status" -eq 0 ]
}

@test "BDD runner exits 2 with 'undefined step' when no step matches" {
  # Synthesize a transient feature whose step does not resolve to any function
  # in any loaded step file. Never touches the real example.sh — so an
  # interrupted test cannot corrupt the working tree.
  local orphan_dir="$BATS_TEST_TMPDIR/specs/orphan-feature"
  mkdir -p "$orphan_dir"
  cat > "$orphan_dir/feature.gherkin" <<'EOF'
Feature: orphan
  Scenario: never resolved
    Given a step that has no matching definition
EOF

  run env OBM_IN_BDD_RUN=1 "$PLUGIN_ROOT/tests/run-bdd.sh" "$orphan_dir/feature.gherkin"

  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi "undefined step"
}
