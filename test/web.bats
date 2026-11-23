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
  size="$(stat -c %s "lib/images/${plasma:0:2}/$plasma.png")"
  run imageRow "$plasma"
  assert_output --regexp "^\[\"$plasma\",\"png\",$size,\"2026-03-04\",\[1,2\]\]"
  run imageRow "$anim"
  assert_output --regexp ",null,\[3\]\]"
}

@test "webDataJs records how many hash characters tell images apart" {
  local a b c
  a="0060d$(printf '0%.0s' {1..35})"
  b="0061a$(printf '0%.0s' {1..35})"
  c="7f$(printf '0%.0s' {1..38})"
  run webDataJs 0 < <(printf 'I\t%s.jpg\t1\n' "$a" "$b" "$c")
  assert_success
  assert_output --partial '"prefix":4};'
  assert_output --partial "[\"$a\",\"jpg\""
}

@test "webDataJs prefix is 1 for one image, and 0 for none" {
  run webDataJs 0 < <(printf 'I\t%s.png\t1\n' "$(printf 'a%.0s' {1..40})")
  assert_output --partial '"prefix":1};'
  run webDataJs 0 < /dev/null
  assert_output --partial '"prefix":0};'
}

@test "buildWeb numbers the first tag 0, not blank" {
  tagImage "$anim" Animal
  buildWeb 2> /dev/null
  run imageRow "$anim"
  assert_output --regexp ",null,\[0,3\]\]"
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
  webStamp "$(date +%s)"
  run cat "$SIL_LIBRARY/web/silStamp.js"
  assert_output --partial '"built":123,'
  assert_output --partial '"command":"sil TAG=\"Dog\" x.jpg"'
}

@test "sil runs update the stamp only when they change the library" {
  buildWeb 2> /dev/null
  local stamp="$SIL_LIBRARY/web/silStamp.js"
  sed -i 's/"changed":[0-9]*/"changed":1/' "$stamp"
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" CHECK
  assert_success
  assert_file_contains "$stamp" '"changed":1,'
  ## Already tagged Meme: nothing changes
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" TAG=Meme "$plasma"
  assert_success
  assert_file_contains "$stamp" '"changed":1,'
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" TAG=Cat "$plasma"
  assert_success
  assert_file_not_contains "$stamp" '"changed":1,'
  assert_file_contains "$stamp" 'TAG=Cat'
}

@test "a run that changes the library before its BUILDWEB leaves fresh data" {
  buildWeb 2> /dev/null
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" TAG=Dog BUILDWEB "$plasma"
  assert_success
  local built changed
  built="$(grep -o '"built":[0-9]*' "$SIL_LIBRARY/web/imageData.js")"
  changed="$(grep -o '"changed":[0-9]*' "$SIL_LIBRARY/web/silStamp.js")"
  assert_equal "${changed#*:}" "${built#*:}"
}

@test "recording GITWEB keeps the stamp's change time and command" {
  buildWeb 2> /dev/null
  local stamp="$SIL_LIBRARY/web/silStamp.js"
  sed -i 's/"changed":[0-9]*/"changed":1/; s/"command":".*"/"command":"sil TAG=\\"Dog\\" x.jpg"/' "$stamp"
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" GITWEB=on
  assert_success
  assert_file_contains "$stamp" '"changed":1,'
  assert_file_contains "$stamp" '"command":"sil TAG=\\"Dog\\" x.jpg",'
  assert_file_contains "$stamp" '"gitweb":true'
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

@test "buildWeb data is valid JavaScript for tag folders SIL wouldn't make" {
  command -v node > /dev/null || skip "node is not installed"
  mkdir -p "$SIL_LIBRARY/tags/Say \"Hi\"" "$SIL_LIBRARY/tags/Back\\slash"
  tagImage "$plasma" 'Say "Hi"'
  buildWeb 2> /dev/null
  run node -e 'global.window = {}; require(process.argv[1]);
    const d = window.SIL_DATA, im = d.images.find((i) => i[0] === process.argv[2]);
    console.log(d.tags.filter((t) => /["\\]/.test(t)).join("|"));
    console.log(im[4].map((n) => d.tags[n]).join("|"))' "$SIL_LIBRARY/web/imageData.js" "$plasma"
  assert_success
  assert_line --index 0 'Back\slash|Say "Hi"'
  assert_line --index 1 --partial 'Say "Hi"'
}

## The stamp's GITWEB value
function stampGitweb {
  grep -o '"gitweb":[a-z]*' "$SIL_LIBRARY/web/silStamp.js"
}

@test "web data files start with a comment saying they are generated" {
  buildWeb 2> /dev/null
  local f
  for f in WebSIL.html web/websil.js web/websil.css web/imageData.js web/silStamp.js; do
    ## The opening comment, up to its close
    run sed -n '1,/\*\/\|-->/p' "$SIL_LIBRARY/$f"
    assert_output --regexp "^(<!doctype html>.)?(/\*|<!--)"
    assert_output --regexp "[Dd]o not[[:space:]]+(\* )?edit"
  done
}

@test "webStamp writes one value to a line, as valid JavaScript" {
  buildWeb 2> /dev/null
  local stamp="$SIL_LIBRARY/web/silStamp.js"
  assert_file_contains "$stamp" '^  "built":[0-9]*,$'
  assert_file_contains "$stamp" '^  "gitweb":false$'
  command -v node > /dev/null || skip "node is not installed"
  run node -e 'global.window = {}; require(process.argv[1]);
    console.log(window.SIL_STAMP.gitweb, window.SIL_STAMP.built > 0)' "$stamp"
  assert_output "false true"
}

@test "GITWEB on lets git share the page, and is kept by later runs" {
  SIL_GITWEB=1
  run buildWeb
  assert_success
  assert_output --partial "git -C '$SIL_LIBRARY' add web WebSIL.html"
  assert_file_not_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
  assert_file_not_contains "$SIL_LIBRARY/.gitignore" '^/WebSIL.html$'
  run stampGitweb
  assert_output '"gitweb":true'
  unset SIL_GITWEB
  webStamp
  run buildWeb
  refute_output --partial "GITWEB"
  run stampGitweb
  assert_output '"gitweb":true'
  assert_file_not_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
}

@test "GITWEB off ignores the page again, and says how to remove committed copies" {
  command -v git > /dev/null || skip "git is not installed"
  SIL_GITWEB=1
  buildWeb 2> /dev/null
  git -C "$SIL_LIBRARY" init -q
  git -C "$SIL_LIBRARY" add web WebSIL.html
  SIL_GITWEB=0
  run buildWeb
  assert_success
  assert_output --partial "rm -r --cached web WebSIL.html"
  assert_file_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
  assert_file_contains "$SIL_LIBRARY/.gitignore" '^/WebSIL.html$'
  run stampGitweb
  assert_output '"gitweb":false'
  run buildWeb
  refute_output --partial "cached"
}

@test "sil GITWEB without BUILDWEB records it for the next build" {
  buildWeb 2> /dev/null
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" WEBGIT
  assert_success
  assert_output --partial "next BUILDWEB applies it"
  run stampGitweb
  assert_output '"gitweb":true'
  assert_file_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" BUILDWEB
  assert_success
  assert_file_not_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
}

@test "sil GITWEB is ignored with a warning for a library without a web page" {
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" GITWEB=on
  assert_success
  assert_output --partial "GITWEB ignored"
  assert_not_exists "$SIL_LIBRARY/web"
}

@test "GITWEB in a manifest is kept after the manifest ends" {
  buildWeb 2> /dev/null
  printf '%s\n' "GITWEB" "$plasma" > m.txt
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" m.txt
  assert_success
  assert_output --partial "next BUILDWEB applies it"
  run stampGitweb
  assert_output '"gitweb":true'
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" BUILDWEB
  assert_success
  assert_file_not_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
}

@test "GITWEB=off in a manifest with BUILDWEB applies to that build" {
  SIL_GITWEB=1
  buildWeb 2> /dev/null
  printf '%s\n' "GITWEB=off" "$plasma" > m.txt
  run "$PROJECT_ROOT/sil" LIBRARY="$SIL_LIBRARY" BUILDWEB m.txt
  assert_success
  refute_output --partial "next BUILDWEB"
  assert_file_contains "$SIL_LIBRARY/.gitignore" '^/web/$'
  run stampGitweb
  assert_output '"gitweb":false'
}
