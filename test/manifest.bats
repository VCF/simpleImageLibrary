#!/usr/bin/env bats
## Tests for src/manifest.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "manifest"
  srcLib "library"
  resetParams
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  mkdir -p work
  cp "$PROJECT_ROOT/test/data/images/plasma.png" \
    "$PROJECT_ROOT/test/data/images/animated.gif" work/
}

teardown() {
  teardown_sandbox
}

@test "parameters apply to the URIs after them; paths are manifest-relative" {
  cat > work/m.txt <<'EOF'
# comment

  tag = First
plasma.png
TAG=Second
animated.gif
EOF
  cd /
  run parseManifest "$TEST_SANDBOX/work/m.txt"
  assert_success
  cd "$TEST_SANDBOX"
  run find lib/tags/First lib/tags/Second -type l
  assert_line --partial "First/"
  assert_line --partial "Second/"
  assert_equal "${#lines[@]}" 2
}

@test "settings are restored after the manifest" {
  SIL_TAG=Outer
  printf 'TAG=Inner\nTHRESHOLD=99\nplasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  assert_equal "$SIL_TAG" Outer
  assert_equal "$SIL_THRESHOLD" 90
}

@test "LIBRARY, CHECK and REBUILD are ignored in a manifest" {
  printf 'LIBRARY=/elsewhere\nCHECK\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "LIBRARY can't be set in a manifest"
  assert_output --partial "CHECK can't be set in a manifest"
  assert_output --partial "[ADDED]"
}

@test "an unknown parameter is reported, not treated as a file" {
  printf 'TAGG=Oops\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "Unrecognized parameter 'TAGG'"
  assert_output --partial "[ADDED]"
}

@test "a failed URI fails the manifest, but later URIs still run" {
  printf 'missing.png\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "[NOFILE]"
  assert_output --partial "[ADDED]"
}
