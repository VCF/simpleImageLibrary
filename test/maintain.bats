#!/usr/bin/env bats
## Tests for src/maintain.sh (CHECK and REBUILD)

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "maintain"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  mkdir -p lib/images lib/tags
  DATA="$PROJECT_ROOT/test/data/images"
  storeImage "$DATA/plasma.png" plasma
  storeImage "$DATA/animated.gif" anim
  PLASMA="lib/images/${plasma:0:2}/${plasma:2:2}/$plasma.png"
}

teardown() {
  teardown_sandbox
}

@test "a healthy library passes CHECK" {
  run libraryCheck
  assert_success
  assert_output --partial "No problems found in 2 stored images"
}

@test "CHECK finds a damaged file" {
  chmod u+w "$PLASMA"
  printf 'x' >> "$PLASMA"
  run libraryCheck
  assert_failure
  assert_output --partial "does not match its name"
}

@test "CHECK finds a file in the wrong folder" {
  mkdir -p lib/images/zz/zz
  mv "$PLASMA" lib/images/zz/zz/
  run libraryCheck
  assert_failure
  assert_output --partial "Stored in the wrong folder"
  assert_output --partial "Fix: move it to images/${plasma:0:2}/${plasma:2:2}/"
}

@test "CHECK finds unexpected files" {
  touch lib/images/holiday.jpg
  run libraryCheck
  assert_failure
  assert_output --partial "Unexpected file in images: images/holiday.jpg"
}

@test "CHECK finds index entries without images, and images not indexed" {
  rm "$PLASMA"
  convert -size 100x100 -seed 5 plasma:fractal new.png
  local h
  h="$(sha1sum new.png | cut -c1-40)"
  mkdir -p "lib/images/${h:0:2}/${h:2:2}"
  cp new.png "lib/images/${h:0:2}/${h:2:2}/$h.png"
  run libraryCheck
  assert_failure
  assert_output --partial "lists an image that isn't stored: $plasma"
  assert_output --partial "Not in fingerprint index: images/${h:0:2}/${h:2:2}/$h.png"
  assert_output --partial "sil REBUILD"
}

@test "CHECK finds malformed and repeated index lines" {
  echo "garbage" >> lib/images/fingerprints.txt
  grep "^$anim " lib/images/fingerprints.txt > repeat.txt
  cat repeat.txt >> lib/images/fingerprints.txt
  run libraryCheck
  assert_failure
  assert_output --partial "Malformed fingerprint index line"
  assert_output --partial "listed twice in fingerprint index: $anim"
}

@test "CHECK finds broken tag links" {
  mkdir -p lib/tags/Animal
  ln -s ../../images/no/ne/missing.jpg lib/tags/Animal/missing.jpg
  run libraryCheck
  assert_failure
  assert_output --partial "Broken tag link: tags/Animal/missing.jpg"
}

@test "REBUILD regenerates a damaged index, matching the original" {
  cp lib/images/fingerprints.txt original.txt
  echo "garbage" > lib/images/fingerprints.txt
  indexRebuild
  run diff <(grep -v '^#' original.txt | sort) \
    <(grep -v '^#' lib/images/fingerprints.txt | sort)
  assert_success
  run libraryCheck
  assert_success
}

@test "REBUILD skips unexpected files and leaves no temp files" {
  touch lib/images/holiday.jpg
  indexRebuild
  run grep -c -v '^#' lib/images/fingerprints.txt
  assert_output 2
  run find lib/images -maxdepth 1 -name 'fingerprints.txt.*'
  assert_output ""
}

@test "sil REBUILD CHECK runs both, rebuild first" {
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
  rm lib/images/fingerprints.txt
  cd lib
  run "$PROJECT_ROOT/sil" CHECK REBUILD
  assert_success
  assert_output --partial "Fingerprint index rebuilt: 2 images"
  assert_output --partial "No problems found"
}

@test "sil CHECK exits 1 on problems" {
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
  touch lib/images/stray.txt
  run "$PROJECT_ROOT/sil" LIBRARY=lib CHECK
  assert_failure 1
}
