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

@test "imageFormat recognizes AVIF" {
  ffmpeg -v error -i "$DATA/plasma.png" -c:v libaom-av1 -still-picture 1 \
    -pix_fmt yuv420p still.avif
  run imageFormat still.avif
  assert_success
  assert_output AVIF
}

# --- animations ------------------------------------------------------

## Write a 3 frame animated GIF: black, plasma, black (0.2 s each)
blankOpening() {
  convert -size 120x80 xc:black \( "$DATA/plasma.png" -resize 120x80! \) \
    -size 120x80 xc:black -set delay 20 -loop 0 "$1"
}

@test "frameDurations reads GIF, WebP and AVIF frame times" {
  blankOpening anim.gif
  run frameDurations anim.gif GIF
  assert_output "$(printf '0.200000\n0.200000\n0.200000')"
  convert anim.gif anim.webp
  run frameDurations anim.webp WEBP
  assert_output "$(printf '0.20\n0.20\n0.20')"
  ffmpeg -v error -i anim.gif -fps_mode passthrough -c:v libaom-av1 \
    -pix_fmt yuv420p anim.avif
  run frameDurations anim.avif AVIF
  assert_output "$(printf '0.200000\n0.200000\n0.200000')"
}

@test "frameDurations treats a WebP delay of 0 as 0.1 seconds" {
  convert -size 20x20 xc:red xc:blue -set delay 0 anim.webp
  run frameDurations anim.webp WEBP
  assert_output "$(printf '0.10\n0.10')"
}

@test "frameDurations gives nothing for still formats" {
  run frameDurations "$DATA/plasma.png" PNG
  assert_output ""
}

@test "imageFrames counts animated AVIF frames, which ImageMagick can't" {
  blankOpening anim.gif
  ffmpeg -v error -i anim.gif -fps_mode passthrough -c:v libaom-av1 \
    -pix_fmt yuv420p anim.avif
  run identify -format '%n' anim.avif
  assert_output 1
  run imageFrames anim.avif
  assert_output 3
  run imageFrames "$DATA/plasma.png"
  assert_output 1
}

@test "middleFrame picks the frame on screen halfway through" {
  run middleFrame <<< "$(printf '0.1\n0.1\n0.1\n0.1')"
  assert_output 2
  ## A long first frame covers the midpoint
  run middleFrame <<< "$(printf '3\n0.1\n0.1')"
  assert_output 0
  run middleFrame <<< "$(printf '0.1\n0.1\n3')"
  assert_output 2
  ## No durations: the middle by count
  run middleFrame <<< "$(printf '0\n0\n0\n0\n0')"
  assert_output 2
}

@test "animations are fingerprinted from the middle frame, not the first" {
  blankOpening anim.gif
  convert "$DATA/plasma.png" -resize 120x80! middle.png
  fingerprintsMatch "$(imageFingerprint anim.gif)" \
    "$(imageFingerprint middle.png)" 95
}

@test "animation fingerprints agree across GIF, WebP and AVIF" {
  blankOpening anim.gif
  convert anim.gif anim.webp
  ffmpeg -v error -i anim.gif -fps_mode passthrough -c:v libaom-av1 \
    -pix_fmt yuv420p anim.avif
  local fp copy
  fp="$(imageFingerprint anim.gif)"
  for copy in anim.webp anim.avif; do
    fingerprintsMatch "$fp" "$(imageFingerprint "$copy")" 95
  done
}

@test "animation frames are fingerprinted on white" {
  ## A black disc on a transparent background, in every frame
  convert -size 120x80 xc:none -fill black -draw 'circle 60,40 60,10' \
    -duplicate 2 -set delay 20 -set dispose background disc.gif
  convert -size 120x80 xc:white -fill black -draw 'circle 60,40 60,10' white.png
  fingerprintsMatch "$(imageFingerprint disc.gif)" \
    "$(imageFingerprint white.png)" 95
}

@test "imageFingerprint keeps STDIN for the caller" {
  blankOpening anim.gif
  local line
  printf 'anim.gif\n/second/line\n' | {
    read -r line
    imageFingerprint "$line" > /dev/null
    read -r line
    assert_equal "$line" /second/line
  }
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

# --- videos ----------------------------------------------------------

## Write a 2 second, 10 frame/second test video with sound. The container
## comes from the suffix; videos are then copied to suffix-free names
makeVideo() {
  local codec=libx264
  [[ "$1" == *.webm ]] && codec=libvpx-vp9
  ffmpeg -v error -y -f lavfi -i testsrc=size=160x120:rate=10:duration=2 \
    -f lavfi -i sine=d=2 -c:v "$codec" -pix_fmt yuv420p -shortest "$1"
}

@test "imageFormat recognizes MP4, WebM and MOV videos by content" {
  makeVideo v.mp4
  makeVideo v.webm
  makeVideo v.mov
  cp v.mp4 mp4
  run imageFormat mp4
  assert_success
  assert_output MP4
  cp v.webm webm
  run imageFormat webm
  assert_output WEBM
  cp v.mov mov
  run imageFormat mov
  assert_output MOV
}

@test "imageFormat flags a truncated video as damaged (2)" {
  makeVideo v.mp4
  head -c 2000 v.mp4 > truncated
  run imageFormat truncated
  assert_failure 2
  assert_output MP4
}

@test "frameDurations and imageFrames read video frames" {
  makeVideo v.mp4
  run imageFrames v.mp4
  assert_output 20
  run frameDurations v.mp4 MP4
  assert_line --index 0 0.100000
}

@test "a video is fingerprinted from its middle frame" {
  makeVideo v.mp4
  ffmpeg -v error -i v.mp4 -vf "select=eq(n\,10)" -frames:v 1 mid.png
  run fingerprintsMatch "$(imageFingerprint v.mp4)" "$(imageFingerprint mid.png)" 95
  assert_success
}

@test "hasAudio tells videos with sound from those without" {
  makeVideo v.mp4
  run hasAudio v.mp4
  assert_success
  ffmpeg -v error -i v.mp4 -an -c copy silent.mp4
  run hasAudio silent.mp4
  assert_failure
}

# --- size and animation (KEEPLARGER) ---------------------------------

@test "imageDimensions reads stills, GIFs and videos" {
  run imageDimensions "$PROJECT_ROOT/test/data/images/plasma.png"
  assert_output 320x240
  run imageDimensions "$PROJECT_ROOT/test/data/images/animated.gif"
  assert_output 120x120
  ffmpeg -v error -i "$PROJECT_ROOT/test/data/images/animated.gif" -pix_fmt yuv420p clip.mp4 < /dev/null
  run imageDimensions clip.mp4
  assert_output 120x120
}

@test "imageDimensions fails for something unreadable" {
  run imageDimensions "$PROJECT_ROOT/test/data/images/not-an-image.jpg"
  assert_failure
}

@test "isAnimated tells stills from animations and videos" {
  run isAnimated "$PROJECT_ROOT/test/data/images/plasma.png"
  assert_failure
  run isAnimated "$PROJECT_ROOT/test/data/images/animated.gif"
  assert_success
  ffmpeg -v error -i "$PROJECT_ROOT/test/data/images/animated.gif" -pix_fmt yuv420p clip.mp4 < /dev/null
  run isAnimated clip.mp4
  assert_success
}
