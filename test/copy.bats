#!/usr/bin/env bats
## Tests for src/copy.sh: COPY and MOVE blocks in manifests

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "manifest"
  sil="$PROJECT_ROOT/sil"
  "$sil" LIBRARY=a TAG=Animal/Dog,Fun "$PROJECT_ROOT/test/data/images/plasma.png" \
    "$PROJECT_ROOT/test/data/images/animated.gif" 2> /dev/null
  "$sil" LIBRARY=b 2> /dev/null
  png="$(storedHash a png)"
  gif="$(storedHash a gif)"
}

teardown() {
  teardown_sandbox
}

# The hash of the one stored image of a type in a library
storedHash() {
  find "$1/images" -name "*.$2" -printf '%f\n' | cut -c1-40
}

@test "copyBlockLine recognizes COPY and MOVE and their aliases, in any case" {
  copyBlockLine 'COPY a -> b' . mode value
  assert_equal "$mode $value" "COPY a -> b"
  copyBlockLine 'mv=b' . mode value
  assert_equal "$mode $value" "MOVE b"
  copyBlockLine 'SilCopy' . mode value
  assert_equal "$mode $value" "COPY "
  run copyBlockLine 'TAG=Fun' . mode value
  assert_failure
  run copyBlockLine 'copyright.jpg' . mode value
  assert_failure
}

@test "copyBlockLine leaves a line naming an existing file as a URI" {
  touch 'copy of cat.jpg'
  run copyBlockLine 'copy of cat.jpg' . mode value
  assert_failure
}

@test "COPY copies an image with its tags and sources, dated today" {
  printf 'COPY a -> b\n%s\n' "$png" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[COPIED] $TEST_SANDBOX/b: ADDED ${png:0:12}"
  assert_file_exists "b/images/${png:0:2}/${png:2:2}/$png.png"
  assert_link_exists "b/tags/Animal/Dog/$png.png"
  assert_link_exists "b/tags/Fun/$png.png"
  run find b/tags/Date -name "$png.png"
  assert_output --partial "/$(date +%Y-%m-%d)/"
  run grep "^$png " b/images/sources.txt
  assert_output "$png file:plasma.png"
  run grep -c '^[0-9a-f]' b/images/fingerprints.txt
  assert_output 1
  assert_file_exists "a/images/${png:0:2}/${png:2:2}/$png.png"
}

@test "COPY copies an animated AVIF, which ImageMagick can't identify unaided" {
  ## Unlike animated.gif, which is already in the source library
  convert -size 60x40 xc:red xc:blue -set delay 20 anim.gif
  ffmpeg -v error -i anim.gif -fps_mode passthrough -c:v libaom-av1 \
    -pix_fmt yuv420p anim.avif
  "$sil" LIBRARY=a anim.avif 2> /dev/null
  local avif
  avif="$(storedHash a avif)"
  printf 'COPY a -> b\n%s\n' "$avif" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[COPIED] $TEST_SANDBOX/b: ADDED ${avif:0:12}"
  assert_file_exists "b/images/${avif:0:2}/${avif:2:2}/$avif.avif"
}

@test "COPY updates the web page stamp of the target, not the source" {
  "$sil" LIBRARY=a BUILDWEB 2> /dev/null
  "$sil" LIBRARY=b BUILDWEB 2> /dev/null
  sed -i 's/"changed":[0-9]*/"changed":1/' a/web/silStamp.js b/web/silStamp.js
  printf 'COPY a -> b\n%s\n' "$png" > m.txt
  run "$sil" m.txt
  assert_success
  assert_file_contains a/web/silStamp.js '"changed":1,'
  assert_file_not_contains b/web/silStamp.js '"changed":1,'
  sed -i 's/"changed":[0-9]*/"changed":1/' a/web/silStamp.js
  printf 'MOVE a -> b\n%s\n' "$png" > m.txt
  run "$sil" m.txt
  assert_success
  assert_file_not_contains a/web/silStamp.js '"changed":1,'
  run find a/.tmp -name '*.start'
  assert_output ""
}

@test "MOVE copies, then removes the image from the source" {
  printf 'MOVE a -> b\n%s\n' "$gif" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[MOVED]"
  assert_file_exists "b/images/${gif:0:2}/${gif:2:2}/$gif.gif"
  assert_link_exists "b/tags/Fun/$gif.gif"
  run find a -name "$gif.*"
  assert_output ""
  run grep -c "^$gif " a/images/fingerprints.txt a/images/sources.txt
  assert_output --partial "fingerprints.txt:0"
  assert_output --partial "sources.txt:0"
}

@test "without a source, the library in use is copied from; '>' is an arrow" {
  mkdir a/lists
  printf 'COPY ../../b\n%s\nMOVE %s > ../../b\n%s\n' "$png" "$TEST_SANDBOX/a" "$gif" > a/lists/m.txt
  cd /
  run "$sil" "$TEST_SANDBOX/a/lists/m.txt"
  assert_success
  assert_output --partial "[COPIED]"
  assert_output --partial "[MOVED]"
}

@test "a duplicate in the target isn't stored again, but gains the tags" {
  "$sil" LIBRARY=b TAG=Other "$PROJECT_ROOT/test/data/images/plasma.png" 2> /dev/null
  printf 'MOVE a -> b\n%s\n' "$png" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[MOVED] $TEST_SANDBOX/b: DUPE ${png:0:12} - already in library (0 of 256 bits differ)"
  run find b/tags -name "$png.png" -path '*/Fun/*' -o -name "$png.png" -path '*/Other/*'
  assert_equal "${#lines[@]}" 2
  run grep -c '^[0-9a-f]' b/images/fingerprints.txt
  assert_output 1
  run find a/images -name "$png.png"
  assert_output ""
}

@test "copied tags follow the target's remaps" {
  "$sil" LIBRARY=b 'REMAP=Fun -> Humor' 2> /dev/null
  printf 'COPY a -> b\n%s\n' "$png" > m.txt
  "$sil" m.txt 2> /dev/null
  assert_link_exists "b/tags/Humor/$png.png"
  assert_not_exists b/tags/Fun
}

@test "TAG doesn't apply to copies; an image without tags is Untagged" {
  "$sil" LIBRARY=a UNTAG='*' "$png" 2> /dev/null
  printf 'TAG=Extra\nCOPY a -> b\n%s\n' "$png" > m.txt
  "$sil" m.txt 2> /dev/null
  assert_not_exists b/tags/Extra
  assert_link_exists "b/tags/Untagged/$png.png"
}

@test "a block ends at any other line; STOPCOPY only ends it" {
  printf 'LIBRARY=a\nCOPY a -> b\n# comment\n\n%s\nSTOPCOPY\n%s\n' "$png" "$gif" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[COPIED]"
  assert_output --partial "[FOUND] ${gif:0:12}"
  run find b/images -name '*.gif'
  assert_output ""
}

@test "STOPCOPY after a MOVE block is fine, and the block ends" {
  printf 'LIBRARY=a\nMOVE a -> b\n%s\nSTOPCOPY\n%s\n' "$gif" "$png" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "[FOUND] ${png:0:12}"
}

@test "URIs after a block still need a library" {
  printf 'COPY a -> b\n%s\nSTOPCOPY\n%s\n' "$png" "$gif" > m.txt
  run "$sil" m.txt
  assert_failure
  assert_output --partial "[COPIED]"
  assert_output --partial "No library for the URIs from line 4 - rest of manifest skipped"
}

@test "a hash not in the source fails as NOHASH" {
  printf 'COPY a -> b\n%s\n' 0123456789abcdef0123456789abcdef01234567 > m.txt
  run "$sil" m.txt
  assert_failure
  assert_output --partial "[NOHASH]"
}

@test "a missing target fails the block as NOLIBRARY, creating nothing" {
  printf 'COPY a -> nowhere\n%s\n%s\n' "$png" "$gif" > m.txt
  run "$sil" m.txt
  assert_failure
  assert_output --partial "The target library does not exist: $TEST_SANDBOX/nowhere"
  assert_output --partial "Found in: m.txt line 1"
  run grep -c '^| NOLIBRARY |' m.txt.md
  assert_output 2
  assert_not_exists nowhere
}

@test "WebSIL's placeholder target, a non-library and the same library are refused" {
  mkdir plain
  touch plain/file
  printf 'COPY a -> update/this/path/to/your/desired/destination/library\n%s\nCOPY a -> plain\n%s\nCOPY a -> a\n%s\n' \
    "$png" "$png" "$png" > m.txt
  run "$sil" m.txt
  assert_failure
  assert_output --partial "still the placeholder WebSIL wrote"
  assert_output --partial "not a SIL library"
  assert_output --partial "the same library"
  assert_not_exists update
}

@test "a block's failures can be retried from the error log once corrected" {
  printf 'LIBRARY=a\nTAG=Fun\nhttp://127.0.0.1:1/x.jpg\nCOPY a -> later\n%s\nSTOPCOPY\nhttp://127.0.0.1:1/y.jpg\n' "$png" > m.txt
  "$sil" m.txt 2> /dev/null || :
  run grep -A1 '^COPY=a' m.txt.err
  assert_line --index 0 "COPY=a -> later"
  assert_line --index 1 "$png"
  run grep -A1 '^COPY=$' m.txt.err
  assert_line --index 1 "http://127.0.0.1:1/y.jpg"
  "$sil" LIBRARY=later 2> /dev/null
  grep -v '^http' m.txt.err > retry.txt
  run "$sil" retry.txt
  assert_output --partial "[COPIED] $TEST_SANDBOX/later"
}

@test "the error log writes a block's line again after another setting" {
  _silErrWritten=([COPY]="a -> b" [TAG]=x)
  run logSettingsChanged $'TAG=y\nCOPY=a -> b'
  assert_output $'TAG=y\nCOPY=a -> b'
  _silErrWritten=([COPY]="a -> b" [TAG]=x)
  run logSettingsChanged $'TAG=x\nCOPY=a -> b'
  assert_output ""
}

@test "a target locked by another sil fails the block without halting" {
  exec {fd}>> b/.tmp/library.lock
  flock -n "$fd"
  printf 'COPY a -> b\n%s\n' "$png" > m.txt
  run "$PROJECT_ROOT/sil" m.txt
  exec {fd}>&-
  assert_failure
  assert_output --partial "target library is in use by another sil"
  assert_output --partial "[NOLIBRARY]"
  assert_output --partial "Report: m.txt.md"
}

@test "the target's settings apply to the copy" {
  printf 'THRESHOLD=0\n' > b/sil.conf
  printf 'COPY a -> b\n%s\n%s\n' "$png" "$gif" > m.txt
  run "$sil" m.txt
  assert_success
  assert_output --partial "$TEST_SANDBOX/b: DUPE ${png:0:12}"
}

@test "COPY and MOVE halt on the command line; STOPCOPY is ignored there" {
  run "$sil" LIBRARY=a 'COPY=a -> b' "$png"
  assert_failure
  assert_output --partial "COPY only applies in a manifest"
  run "$sil" LIBRARY=a STOPCOPY "$png"
  assert_success
  assert_output --partial "STOPCOPY only applies in a manifest - ignored"
}
