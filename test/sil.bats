#!/usr/bin/env bats
## Tests for the sil.sh entry point

load test_helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "sil runs through a chain of symlinks" {
  mkdir bin other
  ln -s "$PROJECT_ROOT/sil" other/sil
  ln -s "$TEST_SANDBOX/other/sil" bin/sil
  run bin/sil
  assert_success
  assert_output --partial "Simple Image Library"
}

@test "sil creates a library from LIBRARY alone and reports settings" {
  run "$PROJECT_ROOT/sil" LIBRARY=newlib SHRINK=500kb
  assert_success
  assert_output --partial "Creating new library"
  assert_output --partial "Library: $TEST_SANDBOX/newlib"
  assert_output --partial "SHRINK = 512000 (500.0 KB)"
  assert_output --partial "nothing more to do"
  assert_dir_exists newlib/images
}

## Run a real process holding a library's lock, leaving its PID in holderPid.
## fd 3 is closed so that bats doesn't wait for it
startHolder() {
  bash -c '
    myDir="$PROJECT_ROOT"
    source "$PROJECT_ROOT/src/utils.sh"
    srcLib params
    srcLib library
    useLibrary "$1" 2> /dev/null
    : > ready
    while :; do sleep 0.1; done
  ' holder "$1" 3>&- &
  holderPid=$!
  timeout 10 bash -c 'until [[ -e ready ]]; do sleep 0.1; done'
}

@test "a second sil is refused while one runs, and works once it is killed" {
  mkdir -p lib/images lib/tags
  startHolder lib
  run "$PROJECT_ROOT/sil" LIBRARY=lib CHECK
  kill -9 "$holderPid" 2> /dev/null || :
  assert_failure
  assert_output --partial "Library is in use by another sil"
  assert_output --partial "Held by PID $holderPid"
  refute_output --partial "Checking library"

  ## The holder's last 'sleep' has the lock open until it ends
  sleep 0.5
  run "$PROJECT_ROOT/sil" LIBRARY=lib
  assert_success
  assert_output --partial "nothing more to do"
}

@test "sil notes its command line for any run it refuses" {
  mkdir -p lib/images lib/tags
  run "$PROJECT_ROOT/sil" LIBRARY=lib
  assert_success
  run cat lib/.tmp/library.owner
  assert_line --index 3 "sil LIBRARY=lib"
}

@test "help needs no lock" {
  mkdir -p lib/images lib/tags
  startHolder lib
  run "$PROJECT_ROOT/sil" LIBRARY=lib --help
  kill -9 "$holderPid" 2> /dev/null || :
  assert_success
}

@test "running the same manifest twice leaves the first run's logs alone" {
  mkdir -p lib/images lib/tags work
  cp "$PROJECT_ROOT/test/data/images/plasma.png" work/
  printf 'LIBRARY=%s\nplasma.png\n' "$TEST_SANDBOX/lib" > work/m.txt
  printf 'from the first run\n' | tee work/m.txt.err > work/m.txt.md
  startHolder lib
  run "$PROJECT_ROOT/sil" work/m.txt
  kill -9 "$holderPid" 2> /dev/null || :
  assert_failure
  assert_output --partial "Library is in use by another sil"
  run cat work/m.txt.err
  assert_output "from the first run"
  run cat work/m.txt.md
  assert_output "from the first run"
}

@test "a manifest inside a locked library leaves its logs alone" {
  mkdir -p lib/images lib/tags
  cp "$PROJECT_ROOT/test/data/images/plasma.png" lib/
  printf 'plasma.png\n' > lib/m.txt
  printf 'from the first run\n' | tee lib/m.txt.err > lib/m.txt.md
  startHolder lib
  run "$PROJECT_ROOT/sil" lib/m.txt
  kill -9 "$holderPid" 2> /dev/null || :
  assert_failure
  assert_output --partial "Library is in use by another sil"
  run cat lib/m.txt.err
  assert_output "from the first run"
}

@test "sil halts with instructions when no library is known" {
  run "$PROJECT_ROOT/sil" https://example.com/a.jpg
  assert_failure
  assert_output --partial "No image library found"
}

@test "sil adds images inside a library, summarizes, and fails if any fail" {
  mkdir -p lib/images lib/tags
  cd lib
  run "$PROJECT_ROOT/sil" TAG=Test "$PROJECT_ROOT/test/data/images/plasma.png" missing.jpg
  assert_failure 1
  assert_output --partial "Library: $TEST_SANDBOX/lib"
  assert_output --partial "[ADDED]"
  assert_output --partial "Done: 1 ADDED"
  assert_output --partial "1 failed: 1 NOFILE"
}

@test "sil runs a manifest" {
  mkdir -p lib/images lib/tags
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  printf 'TAG=FromManifest\nplasma.png\n' > m.txt
  run "$PROJECT_ROOT/sil" LIBRARY=lib m.txt
  assert_success
  assert_output --partial "Manifest: m.txt"
  run find lib/tags/FromManifest -type l
  assert_output --regexp '\.png$'
}

@test "sil takes the library from a manifest when none is given" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  printf 'LIBRARY=%s\nTAG=Fine\nplasma.png\n' "$TEST_SANDBOX/fromManifest" > m.txt
  run "$PROJECT_ROOT/sil" m.txt
  assert_success
  assert_output --partial "Library: to be set by the manifest"
  assert_output --partial "[ADDED]"
  assert_dir_exists fromManifest/tags/Fine
}

@test "sil takes the library from the manifest's location when none is given" {
  mkdir -p lib/images lib/tags lib/lists
  cp "$PROJECT_ROOT/test/data/images/plasma.png" lib/lists/
  printf 'TAG=Fine\nplasma.png\n' > lib/lists/m.txt
  run "$PROJECT_ROOT/sil" lib/lists/m.txt
  assert_success
  assert_output --partial "Library: $TEST_SANDBOX/lib (contains this manifest)"
  assert_dir_exists lib/tags/Fine
}

@test "the manifest's location beats ~/.sil.conf, but not the command line" {
  mkdir -p lib/images lib/tags conf/images conf/tags cli/images cli/tags
  cp "$PROJECT_ROOT/test/data/images/plasma.png" lib/
  printf 'plasma.png\n' > lib/m.txt
  echo "LIBRARY=$TEST_SANDBOX/conf" > "$HOME/.sil.conf"
  run "$PROJECT_ROOT/sil" lib/m.txt
  assert_success
  run find lib/images conf/images -type f -name '*.png'
  assert_output --partial "lib/images/"
  refute_output --partial "conf/images/"
  run "$PROJECT_ROOT/sil" LIBRARY=cli lib/m.txt
  assert_success
  run find cli/images -type f -name '*.png'
  assert_output --partial "cli/images/"
}

@test "sil still needs a library for URIs outside manifests" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  printf 'LIBRARY=%s\nplasma.png\n' "$TEST_SANDBOX/fromManifest" > m.txt
  run "$PROJECT_ROOT/sil" plasma.png
  assert_failure
  assert_output --partial "No image library found"
  run "$PROJECT_ROOT/sil" m.txt plasma.png
  assert_failure
  assert_output --partial "No image library found"
}

@test "sil LINK makes a tag alias without any URIs" {
  run "$PROJECT_ROOT/sil" LIBRARY=lib 'LINK=Politics -> Meme/Politics'
  assert_success
  assert_output --partial "Linked: Politics -> Meme/Politics"
  refute_output --partial "nothing more to do"
  assert_link_exists lib/tags/Politics
}

@test "sil REMAP works without any URIs, and applies before URIs given with it" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  run "$PROJECT_ROOT/sil" LIBRARY=lib 'REMAP=Dog -> Animal/Canine'
  assert_success
  assert_output --partial "Remapped: Dog -> Animal/Canine"
  refute_output --partial "nothing more to do"
  run "$PROJECT_ROOT/sil" LIBRARY=lib 'REMAP=Cat -> Animal/Feline' TAG=cat plasma.png
  assert_success
  assert_output --partial "Tagged: Animal/Feline"
  assert_not_exists lib/tags/cat
}

@test "sil acts on a hand-edited remap file with nothing else to do" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  "$PROJECT_ROOT/sil" LIBRARY=lib TAG=Dog plasma.png 2> /dev/null
  echo 'Dog -> Canine' > lib/RemappedTags.txt
  run "$PROJECT_ROOT/sil" LIBRARY=lib
  assert_success
  assert_output --partial "Moved 1 file from Dog to Canine"
  assert_not_exists lib/tags/Dog
}

@test "sil REMOVE and UNTAG act on stored images" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  "$PROJECT_ROOT/sil" LIBRARY=lib TAG=A,B plasma.png 2> /dev/null
  run "$PROJECT_ROOT/sil" LIBRARY=lib UNTAG=a plasma.png
  assert_success
  assert_output --partial "Untagged: a"
  assert_not_exists lib/tags/A
  run "$PROJECT_ROOT/sil" LIBRARY=lib REMOVE plasma.png
  assert_success
  assert_output --partial "Done: 1 REMOVED"
  assert_not_exists lib/tags/B
}

@test "sil writes nothing to STDOUT when processing images" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  printf 'plasma.png\nmissing.png\n' > m.txt
  "$PROJECT_ROOT/sil" LIBRARY=lib plasma.png missing.png m.txt > out.txt 2> err.txt || true
  assert_file_not_empty err.txt
  assert_file_empty out.txt
}

@test "manifests given together don't share settings" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  convert -size 64x64 -seed 3 plasma:fractal other.png
  printf 'TAG=First\nplasma.png\n' > a.txt
  printf 'other.png\n' > b.txt
  run "$PROJECT_ROOT/sil" LIBRARY=lib a.txt b.txt
  assert_success
  run find lib/tags/First lib/tags/Untagged -type l
  assert_equal "${#lines[@]}" 2
  assert_line --regexp "First/"
  assert_line --regexp "Untagged/"
}

@test "the command line beats the sil.conf of a library named by a manifest" {
  mkdir -p other/images other/tags
  printf 'THRESHOLD=70\n' > other/sil.conf
  printf 'LIBRARY=other\nTHRESHOLD=90\n' > m.txt
  run "$PROJECT_ROOT/sil" THRESHOLD=55 m.txt
  assert_output --partial "THRESHOLD = 90, was 55"
}

@test "with no terminal to ask at, a manifest's LINK halts but still reports" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  printf 'TAG=Old\nplasma.png\nLINK=Old -> New/Old\nmissing.png\n' > m.txt
  run setsid -w "$PROJECT_ROOT/sil" LIBRARY=lib m.txt < /dev/null
  assert_failure 1
  assert_output --partial "no terminal to ask at"
  assert_output --partial "Report: m.txt.md"
  assert_file_contains m.txt.md '^| ADDED | '
  assert_file_contains m.txt.md 'SIL needs an answer'
  [[ ! -L lib/tags/Old ]]
}

# --- sharing a library with git (REQ-10) -------------------------------

## Commit everything in a library
commitAll() {
  git -C "$1" add -A
  git -C "$1" -c user.name=Test -c user.email=test@example.invalid \
    commit -q -m "$2"
}

@test "two clones that add different images merge into a consistent library" {
  convert -size 64x64 -seed 1 plasma:fractal first.png
  convert -size 64x64 -seed 2 plasma:fractal second.png
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  "$PROJECT_ROOT/sil" LIBRARY=origin plasma.png 2> /dev/null
  git init -q origin
  commitAll origin start
  git clone -q origin clone
  "$PROJECT_ROOT/sil" LIBRARY=origin TAG=First first.png 2> /dev/null
  commitAll origin first
  "$PROJECT_ROOT/sil" LIBRARY=clone TAG=Second second.png 2> /dev/null
  commitAll clone second
  git -C clone -c user.name=Test -c user.email=test@example.invalid \
    pull -q --no-rebase --no-edit
  run "$PROJECT_ROOT/sil" LIBRARY=clone CHECK
  assert_success
  assert_output --partial "No problems found in 3 stored images"
  run grep -cv '^#' clone/images/sources.txt
  assert_output 3
}

@test "a library still passes CHECK after it is moved" {
  cp "$PROJECT_ROOT/test/data/images/plasma.png" .
  "$PROJECT_ROOT/sil" LIBRARY=lib TAG=Animal/Dog plasma.png 2> /dev/null
  mkdir elsewhere
  mv lib elsewhere/renamed
  run "$PROJECT_ROOT/sil" LIBRARY=elsewhere/renamed CHECK
  assert_success
  assert_output --partial "No problems found in 1 stored images"
}
