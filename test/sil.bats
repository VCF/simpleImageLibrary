#!/usr/bin/env bats
## Tests for the sil.sh entry point

load test_helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "sil runs from a symlink in another folder" {
  mkdir bin
  ln -s "$PROJECT_ROOT/sil.sh" bin/sil
  run bin/sil
  assert_success
  assert_output --partial "Simple Image Library"
}

@test "sil runs through a chain of symlinks" {
  mkdir bin other
  ln -s "$PROJECT_ROOT/sil" other/sil
  ln -s "$TEST_SANDBOX/other/sil" bin/sil
  run bin/sil
  assert_success
  assert_output --partial "Simple Image Library"
}
