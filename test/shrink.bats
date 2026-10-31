#!/usr/bin/env bats
## Tests for src/shrink.sh. Images are generated with ImageMagick's
## plasma, which compresses poorly and so makes large PNGs

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "shrink"
  resetParams
  SIL_SHRINK=$(( 100 * 1024 ))
  convert -size 600x400 -seed 1 plasma:fractal big.png
}

teardown() {
  teardown_sandbox
}

@test "SHRINK of 0 keeps the original untouched" {
  SIL_SHRINK=0
  shrinkImage big.png kept
  assert_equal "$kept" big.png
  assert_file_not_exists big.shrunk.jpg
}

@test "files under SHRINK x SHRINKTRIGGER are not shrunk" {
  SIL_SHRINK=$(( 1024 * 1024 ))
  run shrinkImage big.png kept
  assert_output --partial "under the trigger"
  assert_file_not_exists big.shrunk.jpg
}

@test "large image is shrunk to about the target and verified" {
  shrinkImage big.png kept
  assert_equal "$kept" big.shrunk.jpg
  assert_file_exists big.png
  local bytes
  bytes="$(stat -c %s big.shrunk.jpg)"
  (( bytes <= SIL_SHRINK ))
}

@test "too little saving keeps the original" {
  SIL_SHRINKMINSAVE=100
  run shrinkImage big.png kept
  assert_output --partial "only saved"
  assert_file_not_exists big.shrunk.jpg
}

@test "transparent images are not shrunk without FLATTEN" {
  convert big.png -alpha set -channel A -evaluate set 50% +channel alpha.png
  run shrinkImage alpha.png kept
  assert_output --partial "Set FLATTEN"
  assert_file_not_exists alpha.shrunk.jpg
}

@test "FLATTEN shrinks transparent images and cleans up" {
  convert big.png -alpha set -channel A -evaluate set 50% +channel alpha.png
  SIL_FLATTEN=1
  shrinkImage alpha.png kept
  assert_equal "$kept" alpha.shrunk.jpg
  run hasTransparency alpha.shrunk.jpg
  assert_failure
  assert_file_not_exists alpha.flat.png
}

@test "FLATTEN verifies against the flattened image" {
  ## A disc on a fully transparent background: flattening onto white
  ## changes the fingerprint, so checking against the original would fail
  convert big.png \( -size 600x400 xc:black -fill white \
    -draw 'circle 300,200 300,40' \) -alpha off -compose CopyOpacity \
    -composite disc.png
  SIL_FLATTEN=1
  shrinkImage disc.png kept
  assert_equal "$kept" disc.shrunk.jpg
}

@test "animated images are not shrunk" {
  convert -size 400x400 -seed 2 plasma:fractal -size 400x400 -seed 3 \
    plasma:fractal anim.gif
  SIL_SHRINK=1
  run shrinkImage anim.gif kept
  assert_output --partial "animated"
  assert_file_not_exists anim.shrunk.jpg
}

@test "imagesMatch distinguishes images" {
  convert big.png -quality 80 same.jpg
  convert -size 600x400 -seed 9 plasma:fractal other.png
  imagesMatch big.png same.jpg
  run imagesMatch big.png other.png
  assert_failure
}

@test "a conversion that damages the image is rejected" {
  convert -size 600x400 -seed 9 plasma:fractal other.png
  ## Stand-in convert that produces a different picture
  convert() { command convert other.png -quality 50 "${@: -1}"; }
  run shrinkImage big.png kept
  assert_output --partial "no longer matches"
  assert_file_not_exists big.shrunk.jpg
}
