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

# --- logs (REQ-08) ---------------------------------------------------

@test "the error log lists failures with reasons, as a manifest" {
  printf 'TAG=Before\nmissing-a.png\nplasma.png\nTAG=After\nmissing-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run grep -v '^#' work/m.txt.err
  assert_line --index 0 "FLATTEN=off"
  assert_line "TAG=Before"
  assert_line "TAG=After"
  assert_line "missing-a.png"
  assert_line "missing-b.png"
  refute_line "plasma.png"
  run grep -c '^THRESHOLD=' work/m.txt.err
  assert_output 1
  run grep -B1 '^missing-a.png$' work/m.txt.err
  assert_line --index 0 "# NOFILE: File not found"
}

@test "error log comments are at most 80 characters" {
  printf 'https://%s.invalid/a.jpg\n' "$(printf 'x%.0s' {1..60})" > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run awk '/^#/ && length > 80' work/m.txt.err
  assert_output ""
  run grep -c '^# UNREACHABLE' work/m.txt.err
  assert_output 1
}

@test "a renamed error log retries the failures, with the same settings" {
  printf 'SHRINK=20kb\nTAG=Retry\nlate.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  cp work/plasma.png work/late.png
  mv work/m.txt.err work/retry.txt
  SIL_TAG=Ignored
  run parseManifest work/retry.txt
  assert_success
  assert_output --partial "[SHRINK]"
  run find lib/tags/Retry -type l
  assert_output --regexp '\.jpg$'
}

@test "the report lists outcomes, with legends only for tags that occur" {
  printf 'plasma.png\nplasma.png\nmissing.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run cat work/m.txt.md
  assert_line --index 0 "# Load report for m.txt"
  assert_line --partial "- **ADDED** - "
  assert_line --partial "- **DUPE** - "
  refute_line --partial "**SHRINK**"
  assert_line --regexp '^\| ADDED \| [0-9a-f]{12} \| plasma.png \|$'
  assert_line "# Failed image download"
  assert_line --partial "- **NOFILE** - "
  refute_line --partial "**NOTFOUND**"
  assert_line "| NOFILE | missing.png |"
}

@test "with no failures, the report has no failure section" {
  printf 'plasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  run grep -c "Failed image download" work/m.txt.md
  assert_output 0
  run grep -v '^#' work/m.txt.err
  assert_output ""
}

@test "logs are overwritten on each run" {
  printf 'missing.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  printf 'plasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  run grep -c 'missing.png' work/m.txt.err work/m.txt.md
  assert_output "work/m.txt.err:0
work/m.txt.md:0"
}

@test "| in a URI is escaped in the report" {
  printf 'a|b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  assert_file_contains work/m.txt.md 'a\\|b.png'
}
