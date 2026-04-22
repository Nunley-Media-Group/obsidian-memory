#!/usr/bin/env bats

# tests/unit/default-template.bats — drift guard for the bundled default
# distillation template.
#
# The SHA-256 below is the initial check-in hash for templates/default-
# distillation.md. This test fails loudly whenever that file changes. The
# failure is intentional: `vault-distill.sh` has no inline fallback prompt
# anymore, so a silent edit to the bundled template would change the
# observable prompt text for every user who has not configured their own
# `distill.template_path`. If the change is deliberate, update the hash in
# the same commit as the template change.
#
# To compute a fresh hash:
#
#   shasum -a 256 templates/default-distillation.md
#
# See specs/feature-make-distillation-template-configurable/ (#7) for
# the layering that makes this file the sole source of truth for the
# v0.1 distillation prompt.

setup() {
  load '../helpers/scratch'
  TEMPLATE="$PLUGIN_ROOT/templates/default-distillation.md"
  export TEMPLATE
  EXPECTED_HASH="fe1f1d947291fcb7d4fc87dc87428af890f6a5c2c26acec3793664e402bec6f7"
  export EXPECTED_HASH
}

teardown() { assert_home_untouched; }

@test "default-distillation.md: bundled template exists and is non-empty" {
  [ -r "$TEMPLATE" ]
  [ -s "$TEMPLATE" ]
}

@test "default-distillation.md: SHA-256 matches the pinned hash (drift guard)" {
  local actual
  actual="$(shasum -a 256 "$TEMPLATE" | awk '{print $1}')"
  if [ "$actual" != "$EXPECTED_HASH" ]; then
    printf '\nDefault distillation template has drifted from the pinned hash.\n' >&2
    printf '  file:     %s\n' "$TEMPLATE" >&2
    printf '  expected: %s\n' "$EXPECTED_HASH" >&2
    printf '  actual:   %s\n' "$actual" >&2
    printf '\nIf the change is intentional, update EXPECTED_HASH in this test.\n' >&2
    printf 'Compute the new value with:\n' >&2
    printf '  shasum -a 256 %s\n\n' "$TEMPLATE" >&2
    return 1
  fi
}
