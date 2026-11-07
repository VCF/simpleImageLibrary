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

# --- locking (REQ-12) ---------------------------------------------------

## Hold a library's lock from this shell's own open file, as another process
## would. The next sil, having its own open file, is refused
holdLock() {
  mkdir -p "$1/.tmp"
  exec {heldFd}>> "$1/.tmp/$_silLockFile"
  flock -n "$heldFd"
}

## Write what a lock holder records about itself
writeOwner() {
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "2026-01-02 03:04:05" "sil big.txt" \
    > "$1/.tmp/$_silLockOwnerFile"
}

@test "useLibrary locks the library and notes who holds it" {
  mkdir -p lib/images lib/tags
  _silCommandLine="sil some.txt"
  useLibrary lib
  run flock -n lib/.tmp/library.lock true
  assert_failure
  run cat lib/.tmp/library.owner
  assert_line --index 0 "$$"
  assert_line --index 1 "$(uname -n)"
  assert_line --index 3 "sil some.txt"
}

@test "a library locked elsewhere is refused, naming the holder" {
  mkdir -p lib/images lib/tags
  holdLock lib
  writeOwner lib "$$" "$(uname -n)"
  run useLibrary lib
  assert_failure
  assert_output --partial "Library is in use by another sil: $TEST_SANDBOX/lib"
  assert_output --partial "Held by PID $$ on $(uname -n) since 2026-01-02 03:04:05: sil big.txt"
  assert_output --partial "Let it finish or stop it"
  refute_output --partial "rm '"
}

@test "a holder recorded as ended on this machine is explained" {
  mkdir -p lib/images lib/tags
  holdLock lib
  ## Over the kernel's largest possible PID, so never running
  writeOwner lib 99999999 "$(uname -n)"
  run useLibrary lib
  assert_failure
  assert_output --partial "That process has ended"
  assert_output --partial "rm '$TEST_SANDBOX/lib/.tmp/library.lock'"
}

@test "a holder on another machine can't be checked, and says so" {
  mkdir -p lib/images lib/tags
  holdLock lib
  writeOwner lib 123 another-machine
  run useLibrary lib
  assert_failure
  assert_output --partial "on another-machine since"
  assert_output --partial "cannot tell from here"
  assert_output --partial "rm '$TEST_SANDBOX/lib/.tmp/library.lock'"
}

@test "a refusal still makes sense with no record of the holder" {
  mkdir -p lib/images lib/tags
  holdLock lib
  run useLibrary lib
  assert_failure
  assert_output --partial "Wait for the other sil to finish"
}

@test "a leftover lock file from a dead process does not block" {
  mkdir -p lib/images lib/tags lib/.tmp
  touch lib/.tmp/library.lock
  writeOwner lib 99999999 "$(uname -n)"
  useLibrary lib
  assert_equal "$SIL_LIBRARY" "$TEST_SANDBOX/lib"
}

@test "locking the same library again is not a conflict" {
  mkdir -p lib/images lib/tags
  useLibrary lib
  useLibrary "$TEST_SANDBOX/lib"
  assert_equal "${#_silLibraryLocks[@]}" 1
}

@test "moving to another library keeps the first one locked" {
  mkdir -p lib/images lib/tags other/images other/tags
  useLibrary lib
  useLibrary other
  run flock -n lib/.tmp/library.lock true
  assert_failure
  run flock -n other/.tmp/library.lock true
  assert_failure
}

@test "a library that can't hold a lock file is refused" {
  mkdir -p lib/images lib/tags
  ## Blocks the lock file whatever the user's permissions, even as root
  mkdir -p lib/.tmp/library.lock
  run useLibrary lib
  assert_failure
  assert_output --partial "Could not open the library's lock file"
}

@test "locking clears a killed run's temp files, and nothing else" {
  mkdir -p lib/images lib/tags lib/.tmp/sil.frames
  touch lib/.tmp/sil.abc lib/.tmp/sil.frames/1.png lib/.tmp/keep.me
  run useLibrary lib
  assert_success
  assert_output --partial "Removed 2 temporary file(s)"
  assert_file_not_exists lib/.tmp/sil.abc
  assert_dir_not_exists lib/.tmp/sil.frames
  assert_file_exists lib/.tmp/keep.me
}

@test "a refused run leaves the holder's temp files alone" {
  mkdir -p lib/images lib/tags lib/.tmp
  touch lib/.tmp/sil.inuse
  holdLock lib
  run useLibrary lib
  assert_failure
  assert_file_exists lib/.tmp/sil.inuse
}
