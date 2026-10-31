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
