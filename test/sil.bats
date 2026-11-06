#!/usr/bin/env bats
## Tests for the sil.sh entry point

load test_helper

setup() {
  setup_sandbox
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
}

teardown() {
  teardown_sandbox
}

@test "sil runs from a symlink in another folder" {
  mkdir bin
  ln -s "$PROJECT_ROOT/sil.sh" bin/sil
  run bin/sil
  assert_success
  assert_output --partial "Simple Image Library"
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
