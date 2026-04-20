# tests/features/steps/example.sh — step definitions for the
# `specs/example/feature.gherkin` placeholder feature.
#
# Removing this file exercises the AC3 negative path: tests/run-bdd.sh must
# exit 2 with an "undefined step" error.

# shellcheck shell=bash

given_the_example_placeholder_is_loaded() {
  [ -n "${PLUGIN_ROOT:-}" ]
}

when_the_runner_evaluates_a_trivial_assertion() {
  _example_result=1
}

then_the_assertion_is_true() {
  [ "${_example_result:-0}" = 1 ]
}
