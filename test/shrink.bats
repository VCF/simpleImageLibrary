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
  ## Temp files then go to $TEST_SANDBOX/.tmp, where tests can see them
  SIL_LIBRARY="$TEST_SANDBOX"
  SIL_SHRINK=$(( 100 * 1024 ))
  convert -size 600x400 -seed 1 plasma:fractal big.png
}

teardown() {
  teardown_sandbox
}

## Write a 4 frame plasma animation, with uneven frame times
makeAnimation() {
  convert -delay 10 -size 200x150 -seed 1 plasma:fractal \
    -delay 20 -size 200x150 -seed 2 plasma:fractal \
    -delay 30 -size 200x150 -seed 3 plasma:fractal \
    -delay 40 -size 200x150 -seed 4 plasma:fractal -loop 0 "$1"
}

## Fail if any temporary file was left behind
assert_no_temp_files() {
  [[ -d "$TEST_SANDBOX/.tmp" ]] || return 0
  run find "$TEST_SANDBOX/.tmp" -type f
  assert_output ""
}

@test "SHRINK of 0 keeps the original untouched" {
  SIL_SHRINK=0
  shrinkImage big.png kept
  assert_equal "$kept" big.png
  assert_no_temp_files
}

@test "files under SHRINK x SHRINKTRIGGER are not shrunk" {
  SIL_SHRINK=$(( 1024 * 1024 ))
  shrinkImage big.png kept
  assert_equal "$kept" big.png
  [[ "$_silShrinkNote" == "As is ("*" < 2.0 MB)" ]]
  assert_no_temp_files
}

@test "large image is shrunk to about the target and verified" {
  shrinkImage big.png kept
  assert_not_equal "$kept" big.png
  assert_file_exists big.png
  run imageFormat "$kept"
  assert_output JPEG
  local bytes
  bytes="$(stat -c %s "$kept")"
  (( bytes <= SIL_SHRINK ))
  [[ "$_silShrinkNote" == *" -> "*" KB (saved "*"%)" ]]
}

@test "too little saving keeps the original" {
  SIL_SHRINKMINSAVE=100
  shrinkImage big.png kept
  assert_equal "$kept" big.png
  [[ "$_silShrinkNote" == "As is (saves only "*"% < SHRINKMINSAVE 100%)" ]]
  assert_no_temp_files
}

@test "transparent images are not shrunk without FLATTEN" {
  convert big.png -alpha set -channel A -evaluate set 50% +channel alpha.png
  shrinkImage alpha.png kept
  assert_equal "$kept" alpha.png
  [[ "$_silShrinkNote" == *"set FLATTEN"* ]]
  assert_no_temp_files
}

@test "FLATTEN shrinks transparent images and cleans up" {
  convert big.png -alpha set -channel A -evaluate set 50% +channel alpha.png
  SIL_FLATTEN=1
  shrinkImage alpha.png kept
  assert_not_equal "$kept" alpha.png
  [[ "$_silShrinkNote" == *", flattened onto white" ]]
  run hasTransparency "$kept"
  assert_failure
  ## Only the kept JPEG remains; the flattened copy is gone
  run find "$TEST_SANDBOX/.tmp" -type f
  assert_output "$kept"
}

@test "FLATTEN verifies against the flattened image" {
  ## A disc on a fully transparent background: flattening onto white
  ## changes the fingerprint, so checking against the original would fail
  convert big.png \( -size 600x400 xc:black -fill white \
    -draw 'circle 300,200 300,40' \) -alpha off -compose CopyOpacity \
    -composite disc.png
  SIL_FLATTEN=1
  shrinkImage disc.png kept
  assert_not_equal "$kept" disc.png
}

@test "animations are not shrunk without SHRINKVID" {
  makeAnimation anim.gif
  SIL_SHRINK=1
  shrinkImage anim.gif kept
  assert_equal "$kept" anim.gif
  assert_equal "$_silShrinkNote" "As is (animated; SHRINKVID is off)"
  assert_no_temp_files
}

@test "a conversion that damages the image is rejected" {
  convert -size 600x400 -seed 9 plasma:fractal other.png
  ## Stand-in convert whose JPEG encoding produces a different picture
  convert() {
    if [[ "$*" == *jpeg:extent* ]]; then
      command convert other.png -quality 50 "${@: -1}"
    else
      command convert "$@"
    fi
  }
  run shrinkImage big.png kept
  assert_failure 2
  assert_output --partial "no longer matches the original at 95%"
  assert_output --partial "of 256 fingerprint bits differ"
  assert_output --partial "retry with a different SHRINK"
  assert_no_temp_files
}

# --- SHRINKVID ---------------------------------------------------------

@test "SHRINKVID shrinks an animated GIF to AVIF, keeping its timing" {
  makeAnimation anim.gif
  SIL_SHRINK=0
  SIL_SHRINKVID=LOW
  shrinkImage anim.gif kept
  assert_not_equal "$kept" anim.gif
  run imageFormat "$kept"
  assert_output AVIF
  [[ "$_silShrinkNote" == *" AVIF (saved "* ]]
  assert_equal "$(frameDurations "$kept" AVIF)" "$(frameDurations anim.gif GIF)"
  (( $(stat -c %s "$kept") < $(stat -c %s anim.gif) ))
}

@test "SHRINKVID shrinks an animated WebP to AVIF, keeping its timing" {
  makeAnimation anim.gif
  convert anim.gif -quality 95 anim.webp
  SIL_SHRINKVID=MEDIUM
  shrinkImage anim.webp kept
  run imageFormat "$kept"
  assert_output AVIF
  ## Plus an unseen 0.01 second frame at the end (see encodeAnimation)
  assert_equal "$(frameDurations "$kept" AVIF | awk '{ printf "%.2f\n", $1 }')" \
    "$(frameDurations anim.webp WEBP; echo 0.01)"
  ## Only the kept AVIF remains; the extracted frames are gone
  run find "$TEST_SANDBOX/.tmp" -mindepth 1
  assert_output "$kept"
}

@test "SHRINKVID leaves still images to SHRINK" {
  SIL_SHRINK=0
  SIL_SHRINKVID=LOW
  shrinkImage big.png kept
  assert_equal "$kept" big.png
  assert_no_temp_files
}

@test "SHRINKVID warns about lost transparency, and shrinks onto white" {
  convert -size 200x150 -seed 1 plasma:fractal -fill none -draw 'color 0,0 reset' \
    -alpha set -channel A -fx 'i < w/2 ? 0 : 1' +channel -duplicate 3 \
    -set delay 20 -set dispose background anim.gif
  SIL_SHRINKVID=LOW
  shrinkImage anim.gif kept 2> err.txt
  run cat err.txt
  assert_output --partial "transparency, which AVIF will lose"
  [[ "$_silShrinkNote" == *" AVIF (saved "* ]]
}

@test "SHRINKVID keeps the original when it saves too little" {
  makeAnimation anim.gif
  SIL_SHRINKVID=HIGH
  SIL_SHRINKMINSAVE=100
  shrinkImage anim.gif kept
  assert_equal "$kept" anim.gif
  [[ "$_silShrinkNote" == "As is (saves only "* ]]
  assert_no_temp_files
}

@test "SHRINKVID leaves animations in other formats unchanged" {
  makeAnimation anim.gif
  ffmpeg -v error -i anim.gif -fps_mode passthrough -c:v libaom-av1 \
    -pix_fmt yuv420p anim.avif
  SIL_SHRINKVID=LOW
  shrinkImage anim.avif kept
  assert_equal "$kept" anim.avif
  assert_equal "$_silShrinkNote" "As is (animated AVIF)"
  assert_no_temp_files
}

@test "an animation conversion that damages the image is rejected" {
  makeAnimation anim.gif
  convert -size 200x150 -seed 9 plasma:fractal -duplicate 3 -set delay 25 other.gif
  ## Stand-in ffmpeg whose AVIF encoding is of a different animation
  ffmpeg() {
    if [[ "$*" == *" avif "* ]]; then
      command ffmpeg -v error -y -i other.gif -c:v libaom-av1 -pix_fmt yuv420p \
        -f avif "${@: -1}"
    else
      command ffmpeg "$@"
    fi
  }
  SIL_SHRINKVID=LOW
  run shrinkImage anim.gif kept
  assert_failure 2
  assert_output --partial "no longer matches the original at 90%"
  assert_output --partial "retry with a different SHRINKVID, or SHRINKVID=OFF"
  assert_no_temp_files
}
