#!/usr/bin/env bats
## Tests for the sil.sh entry point

load test_helper

setup() {
  setup_sandbox
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
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

@test "sil creates a library from LIBRARY alone and reports settings" {
  run "$PROJECT_ROOT/sil" LIBRARY=newlib SHRINK=500kb
  assert_success
  assert_output --partial "Created new library"
  assert_output --partial "SHRINK = 512000 (500.0 KB)"
  assert_output --partial "nothing more to do"
  assert_dir_exists newlib/images
}

@test "sil halts with instructions when no library is known" {
  run "$PROJECT_ROOT/sil" https://example.com/a.jpg
  assert_failure
  assert_output --partial "No image library found"
}

@test "sil passes URIs on inside a library, failing if any fail" {
  mkdir -p lib/images lib/tags
  cd lib
  run "$PROJECT_ROOT/sil" TOR https://example.com/a.jpg
  assert_failure 1
  assert_output --partial "Library: $TEST_SANDBOX/lib"
  assert_output --partial "not yet implemented, skipping: https://example.com/a.jpg"
}
