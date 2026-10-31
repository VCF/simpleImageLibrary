#!/usr/bin/env bats
## Tests for src/index.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "index"
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  DATA="$PROJECT_ROOT/test/data/images"
}

teardown() {
  teardown_sandbox
}

@test "storeImage stores under the file hash and indexes it" {
  storeImage "$DATA/plasma.png" hash
  assert_equal "$hash" "$(sha1sum "$DATA/plasma.png" | cut -c1-40)"
  assert_file_exists "lib/images/${hash:0:2}/${hash:2:2}/$hash.png"
  indexHas "$hash"
  run grep -c "^$hash " lib/images/fingerprints.txt
  assert_output 1
  run head -n 1 lib/images/fingerprints.txt
  assert_output --partial "SIL fingerprint index"
}

@test "storeImage uses the content's format for the suffix" {
  convert "$DATA/plasma.png" webp:disguised.jpg
  storeImage disguised.jpg hash
  assert_file_exists "lib/images/${hash:0:2}/${hash:2:2}/$hash.webp"
}

@test "storeImage twice keeps one file and one index line" {
  storeImage "$DATA/plasma.png" hash
  storeImage "$DATA/plasma.png" hash
  run grep -c "^$hash " lib/images/fingerprints.txt
  assert_output 1
}

@test "storeImage refuses non-images" {
  run storeImage "$DATA/not-an-image.jpg" hash
  assert_failure
  run grep -c -v '^#' lib/images/fingerprints.txt
  assert_output 0
}

@test "the index stays sorted by hash as images are added" {
  local f
  for f in plasma.png animated.gif transparent.png; do
    storeImage "$DATA/$f" hash
  done
  run diff <(grep -v '^#' lib/images/fingerprints.txt) \
    <(grep -v '^#' lib/images/fingerprints.txt | LC_ALL=C sort)
  assert_success
}

@test "temp files go in the library's .tmp folder" {
  ## An unusable system temp folder proves it isn't used
  export TMPDIR="$TEST_SANDBOX/no-such-dir"
  storeImage "$DATA/plasma.png" hash
  assert_dir_exists lib/.tmp
  assert_dir_not_exists "$TMPDIR"
  run find lib/.tmp -type f
  assert_output ""
}

@test "findStoredImage finds by hash whatever the suffix" {
  storeImage "$DATA/animated.gif" hash
  run findStoredImage "$hash"
  assert_output "$TEST_SANDBOX/lib/images/${hash:0:2}/${hash:2:2}/$hash.gif"
  run findStoredImage "${hash^^}"
  assert_success
  run findStoredImage 0000000000000000000000000000000000000000
  assert_failure
  run findStoredImage "not-a-hash"
  assert_failure
}

@test "indexMatch finds a resized copy, closest first" {
  storeImage "$DATA/plasma.png" orig
  convert -size 320x240 -seed 99 plasma:fractal other.png
  storeImage other.png other
  convert "$DATA/plasma.png" -resize 50% half.png
  run indexMatch "$(imageFingerprint half.png)" 90
  assert_success
  assert_line --index 0 --regexp "^[0-9]+ $orig$"
  refute_output --partial "$other"
}

@test "indexMatch prints nothing for a new image or empty library" {
  rm lib/images/fingerprints.txt
  run indexMatch "$(imageFingerprint "$DATA/plasma.png")" 90
  assert_success
  assert_output ""
  storeImage "$DATA/plasma.png" hash
  convert -size 320x240 -seed 99 plasma:fractal other.png
  run indexMatch "$(imageFingerprint other.png)" 90
  assert_output ""
}

@test "indexMatch reports distances, applying the threshold" {
  ## Hand-built index: fingerprints 0, 12 and 13 bits from all-zero
  local zero
  zero="$(head -c 32 /dev/zero | base64 -w0)"
  indexWriteHeader lib/images/fingerprints.txt
  {
    printf 'a%.0s' {1..40}; printf ' ff0f%060d\n' 0
    printf 'b%.0s' {1..40}; printf ' ff1f%060d\n' 0
    printf 'c%.0s' {1..40}; printf ' %064d\n' 0
  } >> lib/images/fingerprints.txt
  run indexMatch "$zero" 95
  assert_line --index 0 "0 $(printf 'c%.0s' {1..40})"
  assert_line --index 1 "12 $(printf 'a%.0s' {1..40})"
  refute_output --partial bbbb
}
