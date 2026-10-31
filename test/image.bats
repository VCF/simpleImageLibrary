#!/usr/bin/env bats
## Tests for src/image.sh

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "image"
  DATA="$PROJECT_ROOT/test/data/images"
}

teardown() {
  teardown_sandbox
}

## Print a raw fingerprint: the given leading bytes, zero padded to 32
fakeFingerprint() {
  { printf '%b' "$1"; head -c $(( 32 - $2 )) /dev/zero; } | base64 -w0
}

# --- format ----------------------------------------------------------

@test "imageFormat recognizes supported formats by content" {
  run imageFormat "$DATA/plasma.png"
  assert_success
  assert_output PNG
  run imageFormat "$DATA/animated.gif"
  assert_output GIF
  convert "$DATA/plasma.png" webp-as-jpg.jpg
  convert webp-as-jpg.jpg webp:mislabeled
  run imageFormat mislabeled
  assert_output WEBP
}

@test "imageFormat rejects non-images (1)" {
  cp "$DATA/not-an-image.jpg" page
  run imageFormat page
  assert_failure 1
  run imageFormat "$DATA/not-an-image.jpg"
  assert_failure 1
}

@test "imageFormat flags damaged images (2)" {
  convert "$DATA/plasma.png" -quality 90 whole.jpg
  head -c 3000 whole.jpg > truncated
  run imageFormat truncated
  assert_failure 2
  assert_output JPEG
}

@test "imageFormat rejects SVG as unsupported (3)" {
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"/>' > pic
  run imageFormat pic
  assert_failure 3
  assert_output SVG
}

# --- fingerprints ----------------------------------------------------

@test "imageFingerprint gives 44 base64 characters" {
  run imageFingerprint "$DATA/plasma.png"
  assert_success
  assert_output --regexp '^[A-Za-z0-9+/]{43}=$'
}

@test "imageFingerprint fails, with no output, on a non-image" {
  run imageFingerprint "$DATA/not-an-image.jpg"
  assert_failure
  assert_output ""
}

@test "fileHash is the sha1sum of the file" {
  printf 'abc' > f
  run fileHash f
  assert_output "a9993e364706816aba3e25717850c26c9cd0d89d"
  run fileHash missing
  assert_failure
}

@test "fingerprintToHex gives 64 hex characters" {
  run fingerprintToHex "$(fakeFingerprint '\xab' 1)"
  assert_output "ab$(printf '0%.0s' {1..62})"
  run fingerprintToHex "short"
  assert_failure
}

@test "fingerprintDistance counts differing bits" {
  local zero one twelve thirteen
  zero="$(fakeFingerprint '' 0)"
  one="$(fakeFingerprint '\x01' 1)"
  twelve="$(fakeFingerprint '\xff\x0f' 2)"
  thirteen="$(fakeFingerprint '\xff\x1f' 2)"
  run fingerprintDistance "$zero" "$zero"
  assert_output 0
  run fingerprintDistance "$zero" "$one"
  assert_output 1
  run fingerprintDistance "$thirteen" "$zero"
  assert_output 13
  run fingerprintDistance "$zero" "notAFingerprint"
  assert_failure
}

@test "fingerprintsMatch follows the findimagedupes threshold rule" {
  local zero twelve thirteen
  zero="$(fakeFingerprint '' 0)"
  twelve="$(fakeFingerprint '\xff\x0f' 2)"
  thirteen="$(fakeFingerprint '\xff\x1f' 2)"
  fingerprintsMatch "$zero" "$twelve" 95
  run fingerprintsMatch "$zero" "$thirteen" 95
  assert_failure
  fingerprintsMatch "$zero" "$thirteen" 90
}

@test "fingerprints of resized and recompressed copies stay similar" {
  convert "$DATA/plasma.png" -resize 50% half.png
  convert "$DATA/plasma.png" -quality 60 recompressed.jpg
  local fp copy
  fp="$(imageFingerprint "$DATA/plasma.png")"
  for copy in half.png recompressed.jpg; do
    fingerprintsMatch "$fp" "$(imageFingerprint "$copy")" 95
  done
}

@test "different images do not match" {
  convert -size 320x240 -seed 99 plasma:fractal other.png
  run fingerprintsMatch "$(imageFingerprint "$DATA/plasma.png")" \
    "$(imageFingerprint other.png)" 90
  assert_failure
}
