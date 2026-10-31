#!/usr/bin/env bats
## Tests for src/tags.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "tags"
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  storeImage "$PROJECT_ROOT/test/data/images/plasma.png" hash
}

teardown() {
  teardown_sandbox
}

@test "parseTags splits on commas and nests on / or :" {
  run parseTags " Humor , Animal:Mammal/ Dog ,,Meme/ "
  assert_success
  assert_output "Humor
Animal/Mammal/Dog
Meme"
}

@test "parseTags refuses . and .. levels" {
  run parseTags "ok,../../etc,a/./b"
  assert_failure
  assert_output "ok"
}

@test "tagImage links by relative path, named after the image" {
  tagImage "$hash" Animal/Dog
  local link="lib/tags/Animal/Dog/$hash.png"
  assert_link_exists "$link"
  run readlink "$link"
  assert_output "../../../images/${hash:0:2}/${hash:2:2}/$hash.png"
  assert_file_exists "$link"
}

@test "tag folders are reused whatever their case" {
  mkdir -p lib/tags/Animal/Dog
  tagImage "$hash" animal/DOG
  assert_link_exists "lib/tags/Animal/Dog/$hash.png"
  run find lib/tags -mindepth 1 -type d
  assert_output "lib/tags/Animal
lib/tags/Animal/Dog"
}

@test "tagging through an alias folder links correctly" {
  ## As LINK will make: tags/Politics -> Meme/Politics
  mkdir -p lib/tags/Meme/Politics
  ln -s Meme/Politics lib/tags/Politics
  tagImage "$hash" Politics
  assert_link_exists "lib/tags/Meme/Politics/$hash.png"
  assert_file_exists "lib/tags/Meme/Politics/$hash.png"
}

@test "applyTags applies every tag in SIL_TAG, and repeats are harmless" {
  SIL_TAG="Humor, Meme/Classic"
  run applyTags "$hash"
  assert_success
  assert_output --partial "Tagged: Humor, Meme/Classic"
  applyTags "$hash"
  assert_link_exists "lib/tags/Humor/$hash.png"
  assert_link_exists "lib/tags/Meme/Classic/$hash.png"
}

@test "tagImage fails for an image not in the library" {
  run tagImage 0000000000000000000000000000000000000000 Humor
  assert_failure
}

# --- date tags (TAG-02) ----------------------------------------------

## Store a fresh image and date-tag it on a given day; sets $hash
storeOn() {
  convert -size 60x40 -seed "$2" plasma:fractal "img$2.png"
  storeImage "img$2.png" hash
  _silToday="$1" dateTagImage "$hash" 2> /dev/null
}

@test "dateTagImage links into tags/Date/YYYY/YYYY-MM-DD" {
  _silToday=2026-10-31 dateTagImage "$hash"
  assert_link_exists "lib/tags/Date/2026/2026-10-31/$hash.png"
  assert_file_exists "lib/tags/Date/2026/2026-10-31/$hash.png"
}

@test "new days link back and forth, across a year boundary" {
  storeOn 2025-12-30 1
  storeOn 2026-01-02 2
  local d=lib/tags/Date
  run readlink "$d/2026/2026-01-02/previous-2025-12-30"
  assert_output "../../2025/2025-12-30"
  run readlink "$d/2025/2025-12-30/next-2026-01-02"
  assert_output "../../2026/2026-01-02"
  assert_dir_exists "$d/2025/2025-12-30/next-2026-01-02/"
  run find "$d/2025/2025-12-30" -name 'previous-*'
  assert_output ""
}

@test "a second image on the same day adds no day links" {
  storeOn 2026-10-30 1
  storeOn 2026-10-31 2
  storeOn 2026-10-31 3
  run find lib/tags/Date -type l -name 'next-*'
  assert_equal "${#lines[@]}" 1
  run find lib/tags/Date/2026/2026-10-31 -type l ! -name 'previous-*'
  assert_equal "${#lines[@]}" 2
}

@test "a day added out of order is inserted between its neighbours" {
  storeOn 2026-10-01 1
  storeOn 2026-10-31 2
  storeOn 2026-10-15 3
  local d=lib/tags/Date/2026
  assert_link_exists "$d/2026-10-01/next-2026-10-15"
  assert_link_exists "$d/2026-10-15/previous-2026-10-01"
  assert_link_exists "$d/2026-10-15/next-2026-10-31"
  assert_link_exists "$d/2026-10-31/previous-2026-10-15"
  assert_not_exists "$d/2026-10-01/next-2026-10-31"
  dayLinksCorrect
}

@test "relinkDays repairs links after a merge of two clones' days" {
  storeOn 2026-10-30 1
  storeOn 2026-11-02 2
  ## The other clone added 11-01 after 10-30; git keeps both next links
  mkdir -p lib/tags/Date/2026/2026-11-01
  ln -s ../2026-11-01 lib/tags/Date/2026/2026-10-30/next-2026-11-01
  ln -s ../2026-10-30 lib/tags/Date/2026/2026-11-01/previous-2026-10-30
  run dayLinksCorrect
  assert_failure
  relinkDays
  dayLinksCorrect
  assert_link_exists lib/tags/Date/2026/2026-11-01/next-2026-11-02
  assert_not_exists lib/tags/Date/2026/2026-10-30/next-2026-11-02
}

@test "Date is reserved for automatic tags" {
  SIL_TAG="date/2020, Fine"
  run applyTags "$hash"
  assert_failure
  assert_output --partial "'Date' is reserved"
  assert_output --partial "Tagged: Fine"
  assert_not_exists lib/tags/date
}
