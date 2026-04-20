#!/usr/bin/env bats

setup() {
  load '../helpers/scratch'
}

teardown() {
  assert_home_untouched
}

@test "bats integration smoke test runs against scratch HOME" {
  [ -n "$HOME" ]
  [ "$HOME" = "$BATS_TEST_TMPDIR/home" ]
  [ -d "$VAULT" ]
  [ -n "$PLUGIN_ROOT" ]
  [ -d "$PLUGIN_ROOT/scripts" ]
}
