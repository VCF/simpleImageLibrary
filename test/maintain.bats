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
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
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
  assert_output --partial "sil REBUILD moves it to images/${plasma:0:2}/${plasma:2:2}/"
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
  libraryRebuild
  run grep -c -v '^#' lib/images/fingerprints.txt
  assert_output 2
  assert_file_exists lib/images/holiday.jpg
  run find lib/.tmp lib/images -name 'sil.*'
  assert_output ""
}

@test "CHECK reports missing library files; REBUILD restores them" {
  rm lib/.gitignore lib/tags/.gitkeep
  run libraryCheck
  assert_failure
  assert_output --partial "Missing library file: .gitignore"
  assert_output --partial "Missing library file: tags/.gitkeep"
  libraryRebuild
  assert_files_equal lib/.gitignore "$PROJECT_ROOT/templates/gitignore"
  assert_file_exists lib/tags/.gitkeep
}

## Tag an image by hand, as tagging will: tags/<tag>/<file> -> image
tagByHand() {
  local image="$1" tag="$2"
  mkdir -p "lib/tags/$tag"
  ln -s "$(relativePath "lib/tags/$tag" "$image")" "lib/tags/$tag/$(basename "$image")"
}

@test "REBUILD renames an edited image and keeps its tags" {
  tagByHand "$PLASMA" Animal/Dog
  tagByHand "$PLASMA" Meme
  ## Edit in place: still a PNG, but new content and so a new hash
  convert "$PLASMA" -rotate 180 "$PLASMA"
  local new
  new="$(sha1sum "$PLASMA" | cut -c1-40)"
  libraryRebuild
  assert_file_not_exists "$PLASMA"
  assert_file_exists "lib/images/${new:0:2}/${new:2:2}/$new.png"
  assert_file_exists "lib/tags/Animal/Dog/$new.png"
  assert_file_exists "lib/tags/Meme/$new.png"
  run readlink "lib/tags/Animal/Dog/$new.png"
  assert_output "../../../images/${new:0:2}/${new:2:2}/$new.png"
  assert_not_exists "lib/tags/Animal/Dog/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD moves a misplaced image and keeps its tags" {
  mkdir -p lib/images/zz/zz
  mv "$PLASMA" lib/images/zz/zz/
  tagByHand "lib/images/zz/zz/$plasma.png" Bird
  libraryRebuild
  assert_file_exists "$PLASMA"
  assert_dir_not_exists lib/images/zz
  run readlink "lib/tags/Bird/$plasma.png"
  assert_output "../../images/${plasma:0:2}/${plasma:2:2}/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD fixes a wrong suffix and keeps tags" {
  local wrong="${PLASMA%.png}.jpg"
  mv "$PLASMA" "$wrong"
  tagByHand "$wrong" Bird
  libraryRebuild
  assert_file_exists "$PLASMA"
  assert_file_exists "lib/tags/Bird/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD merges a second copy, keeping both copies' tags" {
  ## A copy edited to match another stored image exactly
  local anim="lib/images/${anim:0:2}/${anim:2:2}/$anim.gif"
  tagByHand "$PLASMA" Original
  tagByHand "$anim" Copy
  cp "$PLASMA" "$anim"
  libraryRebuild
  assert_file_not_exists "$anim"
  assert_file_exists "lib/tags/Original/$plasma.png"
  assert_file_exists "lib/tags/Copy/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD leaves unreadable images alone and reports them" {
  local h="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "lib/images/01/23"
  cp "$DATA/not-an-image.jpg" "lib/images/01/23/$h.jpg"
  run libraryRebuild
  assert_failure
  assert_output --partial "Not a readable, supported image, left alone"
  assert_file_exists "lib/images/01/23/$h.jpg"
}

@test "sil REBUILD CHECK runs both, rebuild first" {
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
  rm lib/images/fingerprints.txt
  cd lib
  run "$PROJECT_ROOT/sil" CHECK REBUILD
  assert_success
  assert_output --partial "Added images/fingerprints.txt"
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

@test "REBUILD keeps sources when it renames an image" {
  sourceAdd "$plasma" https://example.com/p.png
  sourceAdd "$plasma" https://example.com/p2.png
  convert "$PLASMA" -rotate 90 "$PLASMA"
  local new
  new="$(sha1sum "$PLASMA" | cut -c1-40)"
  libraryRebuild
  run grep -v '^#' lib/images/sources.txt
  assert_output "$new https://example.com/p.png
$new https://example.com/p2.png"
  run libraryCheck
  assert_success
}

@test "CHECK reports sources for images that aren't stored" {
  sourceAdd 0123456789abcdef0123456789abcdef01234567 https://example.com/gone.png
  run libraryCheck
  assert_failure
  assert_output --partial "Source recorded for an image that isn't stored"
}

@test "CHECK reports, and REBUILD fixes, out of date day links" {
  mkdir -p lib/tags/Date/2026/2026-10-30 lib/tags/Date/2026/2026-10-31
  run libraryCheck
  assert_failure
  assert_output --partial "Date tag next/previous links are out of date"
  libraryRebuild
  run libraryCheck
  assert_success
}
