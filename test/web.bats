#!/usr/bin/env bats
## Tests for src/web.sh (BUILDWEB and the web page stamp)

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "web"
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  DATA="$PROJECT_ROOT/test/data/images"
  _silToday=2026-03-04
  storeImage "$DATA/plasma.png" plasma
  storeImage "$DATA/animated.gif" anim
  dateTagImage "$plasma"
  tagImage "$plasma" Animal/Dog
  tagImage "$plasma" Meme
  markUntagged "$anim"
}

teardown() {
  teardown_sandbox
}

## The data file's line for an image
function imageRow {
  grep "^\[\"$1\"" "$SIL_LIBRARY/web/imageData.js"
}

@test "jsonEscape escapes quotes and backslashes, and blanks control characters" {
  run jsonEscape $'a"b\\c\nd'
  assert_output 'a\"b\\c d'
}

@test "buildWeb writes the page, its files and data" {
  run buildWeb
  assert_success
  assert_output --partial "2 images"
  assert_file_exists "$SIL_LIBRARY/WebSIL.html"
  assert_file_exists "$SIL_LIBRARY/web/websil.js"
  assert_file_exists "$SIL_LIBRARY/web/websil.css"
  assert_file_exists "$SIL_LIBRARY/web/imageData.js"
  assert_file_exists "$SIL_LIBRARY/web/silStamp.js"
}

@test "buildWeb records tags, sizes and dates, leaving out the date tag" {
  buildWeb 2> /dev/null
  local js="$SIL_LIBRARY/web/imageData.js" size
  run grep '^"tags":' "$js"
  assert_output '"tags":["Animal","Animal/Dog","Meme","Untagged"],'
  size="$(stat -c %s "lib/images/${plasma:0:2}/${plasma:2:2}/$plasma.png")"
  run imageRow "$plasma"
  assert_output --regexp "^\[\"$plasma\",\"png\",$size,\"2026-03-04\",\[1,2\]\]"
  run imageRow "$anim"
  assert_output --regexp ",null,\[3\]\]"
}

@test "buildWeb records LINK aliases once, not their contents again" {
  linkTag 'Funny -> Meme' 2> /dev/null
  buildWeb 2> /dev/null
  run grep '^"aliases":' "$SIL_LIBRARY/web/imageData.js"
  assert_output '"aliases":[["Funny","Meme"]],'
  run imageRow "$plasma"
  assert_output --partial ",[1,2]]"
  refute_output --partial "Funny"
}

@test "buildWeb data is valid JavaScript, even for an awkward library path" {
  command -v node > /dev/null || skip "node is not installed"
  local odd="$TEST_SANDBOX/it's \"odd\" \\ here"
  mv "$SIL_LIBRARY" "$odd"
  SIL_LIBRARY="$odd"
  buildWeb 2> /dev/null
  run node -e 'global.window = {}; require(process.argv[1]);
    const d = window.SIL_DATA; console.log(d.library, d.images.length)' "$odd/web/imageData.js"
  assert_success
  assert_output "$odd 2"
}

@test "buildWeb keeps the page out of git, once" {
  grep -v '^/web/$' "$SIL_LIBRARY/.gitignore" > gi && mv gi "$SIL_LIBRARY/.gitignore"
  buildWeb 2> /dev/null
  buildWeb 2> /dev/null
  run grep -c '^/web/$' "$SIL_LIBRARY/.gitignore"
  assert_output 1
}

@test "buildWeb leaves a stamp that doesn't call fresh data out of date" {
  buildWeb 2> /dev/null
  local built changed
  built="$(grep -o '"built":[0-9]*' "$SIL_LIBRARY/web/imageData.js")"
  changed="$(grep -o '"changed":[0-9]*' "$SIL_LIBRARY/web/silStamp.js")"
  assert_equal "${changed#*:}" "${built#*:}"
}

@test "webStamp does nothing for a library without a web page" {
  run webStamp
  assert_success
  assert_not_exists "$SIL_LIBRARY/web"
}

@test "webStamp keeps the build time and records the command" {
  buildWeb 2> /dev/null
  sed -i 's/"built":[0-9]*/"built":123/' "$SIL_LIBRARY/web/silStamp.js"
  _silCommandLine='sil TAG="Dog" x.jpg'
  webStamp
  run cat "$SIL_LIBRARY/web/silStamp.js"
  assert_output --partial '"built":123}'
  assert_output --partial '"command":"sil TAG=\"Dog\" x.jpg"'
}

@test "sil runs update the stamp, except CHECK alone" {
  buildWeb 2> /dev/null
  local stamp="$SIL_LIBRARY/web/silStamp.js"
  sed -i 's/"changed":[0-9]*/"changed":1/' "$stamp"
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" CHECK
  assert_success
  assert_file_contains "$stamp" '"changed":1,'
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" TAG=Cat "$plasma"
  assert_success
  run grep -c '"changed":1,' "$stamp"
  assert_output 0
}

@test "sil BUILDWEB builds after processing its manifests" {
  printf '%s\n' "TAG=Space Ships" "$plasma" > m.txt
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" BUILDWEB m.txt
  assert_success
  assert_file_contains "$SIL_LIBRARY/web/imageData.js" '"Space Ships"'
}

@test "BUILDWEB in a manifest is ignored with a warning" {
  printf '%s\n' "BUILDWEB" "$plasma" > m.txt
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" m.txt
  assert_success
  assert_output --partial "BUILDWEB can't be set in a manifest"
  assert_not_exists "$SIL_LIBRARY/web"
}
