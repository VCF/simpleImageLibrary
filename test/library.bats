#!/usr/bin/env bats
## Tests for src/library.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "library"
  resetParams
}

teardown() {
  teardown_sandbox
}

@test "isLibrary requires both images and tags" {
  mkdir -p lib/images
  run isLibrary lib
  assert_failure
  mkdir lib/tags
  isLibrary lib
}

@test "findLibrary finds the library from deep inside it" {
  mkdir -p lib/images lib/tags/Animal/Dog
  run findLibrary lib/tags/Animal/Dog
  assert_output "$TEST_SANDBOX/lib"
}

@test "findLibrary fails outside any library" {
  mkdir plain
  run findLibrary plain
  assert_failure
}

@test "initLibrary creates folders and copies the templates" {
  initLibrary "$TEST_SANDBOX/new"
  assert_dir_exists new/images
  assert_dir_exists new/tags
  assert_file_exists new/tags/.gitkeep
  assert_file_exists new/images/fingerprints.txt
  assert_files_equal new/sil.conf "$PROJECT_ROOT/templates/sil.conf"
  assert_files_equal new/.gitignore "$PROJECT_ROOT/templates/gitignore"
  assert_files_equal new/.gitattributes "$PROJECT_ROOT/templates/gitattributes"
}

## Minimal git identity so commits work anywhere
gitq() {
  git -c user.name=Test -c user.email=test@example.com \
    -c init.defaultBranch=main "$@" > /dev/null 2>&1
}

@test "a cloned library is still a library; temp files and logs are ignored" {
  initLibrary "$TEST_SANDBOX/lib"
  gitq -C lib init
  gitq -C lib add -A
  gitq -C lib commit -m init
  gitq clone lib copy
  isLibrary copy
  mkdir -p lib/.tmp
  touch lib/.tmp/sil.abc lib/memes.txt.err lib/memes.txt.md
  run git -C lib status --porcelain
  assert_output ""
}

@test "files that two people add to are merged by union" {
  initLibrary "$TEST_SANDBOX/lib"
  git -C lib init -q
  local file
  for file in images/fingerprints.txt images/sources.txt RemappedTags.txt ReplacedImages.tsv; do
    run git -C lib check-attr merge "$file"
    assert_output "$file: merge: union"
  done
}

@test "initLibrary keeps an existing sil.conf" {
  mkdir new
  echo "SHRINK=1mb" > new/sil.conf
  initLibrary "$TEST_SANDBOX/new"
  assert_file_contains new/sil.conf "SHRINK=1mb"
}

@test "resolveLibrary halts with instructions when no library is known" {
  run resolveLibrary
  assert_failure
  assert_output --partial "No image library found"
  assert_output --partial "sil LIBRARY="
}

@test "resolveLibrary uses the library containing the current folder" {
  mkdir -p lib/images lib/tags/Bird
  cd lib/tags/Bird
  resolveLibrary
  assert_equal "$SIL_LIBRARY" "$TEST_SANDBOX/lib"
}

@test "current folder library beats ~/.sil.conf default" {
  mkdir -p lib/images lib/tags other/images other/tags
  echo "LIBRARY=$TEST_SANDBOX/other" > "$HOME/.sil.conf"
  cd lib
  loadParams
  resolveLibrary
  assert_equal "$SIL_LIBRARY" "$TEST_SANDBOX/lib"
}

@test "~/.sil.conf default is used outside any library, with ~ expanded" {
  mkdir -p home/pics/images home/pics/tags
  echo "LIBRARY=~/pics" > "$HOME/.sil.conf"
  loadParams
  resolveLibrary
  assert_equal "$SIL_LIBRARY" "$HOME/pics"
}

@test "command line LIBRARY beats the current folder library" {
  mkdir -p lib/images lib/tags
  cd lib
  loadParams LIBRARY=../other
  resolveLibrary
  assert_equal "$SIL_LIBRARY" "$TEST_SANDBOX/other"
  assert_dir_exists "$TEST_SANDBOX/other/images"
}

@test "an empty existing folder becomes a library" {
  mkdir empty
  loadParams LIBRARY=empty
  resolveLibrary
  assert_dir_exists empty/tags
}

@test "a non-empty non-library folder is refused" {
  mkdir stuff
  touch stuff/photo.jpg
  loadParams LIBRARY=stuff
  run resolveLibrary
  assert_failure
  assert_output --partial "not a SIL library, and is not empty"
  assert_dir_not_exists stuff/images
}

@test "a file as LIBRARY is refused" {
  touch afile
  loadParams LIBRARY=afile
  run resolveLibrary
  assert_failure
  assert_output --partial "not a folder"
}
