#!/usr/bin/env bats
## Tests for src/fetch.sh and src/ingest.sh. URLs are served by a local
## Python web server, so no network access is needed

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "ingest"
  srcLib "library"
  resetParams
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  DATA="$PROJECT_ROOT/test/data/images"
}

teardown() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2> /dev/null
  teardown_sandbox
}

## Serve the sandbox's www folder; sets URL to its base address
startServer() {
  mkdir -p www
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory www > server.log 2>&1 &
  SERVER_PID=$!
  local i port
  for i in {1..50}; do
    port="$(grep -o 'port [0-9]*' server.log | grep -o '[0-9]*' || true)"
    [[ -n "$port" ]] && break
    sleep 0.1
  done
  URL="http://127.0.0.1:$port"
}

## Fail if any temporary file was left behind
assert_no_temp_files() {
  [[ -d lib/.tmp ]] || return 0
  run find lib/.tmp -type f
  assert_output ""
}

# --- classification --------------------------------------------------

@test "uriKind tells URLs, hashes and paths apart" {
  run uriKind https://example.com/a.jpg
  assert_output url
  run uriKind 85B903EE6717F8B93AE17684CB4284638094A8EA
  assert_output hash
  run uriKind some/file.jpg
  assert_output path
  touch 85b903ee6717f8b93ae17684cb4284638094a8ea
  run uriKind 85b903ee6717f8b93ae17684cb4284638094a8ea
  assert_output path
}

# --- local files -----------------------------------------------------

@test "a local image is ADDED and tagged; no temp files remain" {
  SIL_TAG=Test
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "[ADDED]"
  assert_output --partial "Tagged: Test"
  refute_output --partial "Tagged: Untagged"
  run find lib/tags/Test -type l
  assert_output --regexp '\.png$'
  assert_no_temp_files
}

@test "a new image given no tags reports the Untagged tag" {
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "Tagged: Untagged"
}

@test "a line number, when given, is shown before the URI" {
  run processURI "$DATA/plasma.png" "" 7
  assert_output --partial "[7] $DATA/plasma.png"
}

@test "a large image is shrunk (SHRINK)" {
  SIL_SHRINK=51200
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "[SHRINK]"
  run find lib/images -name '*.jpg'
  assert_output --regexp '\.jpg$'
  assert_no_temp_files
}

@test "the same image again is a DUPE, and new tags go to the original" {
  processURI "$DATA/plasma.png" 2> /dev/null
  SIL_TAG=Again
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "[DUPE]"
  assert_output --partial "(0 of 256 bits differ)"
  run find lib/images -type f -name '*.png'
  assert_line --index 0 --regexp 'png$'
  assert_equal "${#lines[@]}" 1
  run find lib/tags/Again -type l
  assert_output --regexp '\.png$'
}

@test "a resized copy is a DUPE of the original" {
  processURI "$DATA/plasma.png" 2> /dev/null
  convert "$DATA/plasma.png" -resize 50% half.png
  run processURI half.png
  assert_output --partial "[DUPE]"
}

@test "a hash URI is FOUND and tagged; an unknown one is NOHASH" {
  processURI "$DATA/plasma.png" 2> /dev/null
  local hash
  hash="$(sha1sum "$DATA/plasma.png" | cut -c1-40)"
  SIL_TAG=ByHash
  run processURI "${hash^^}"
  assert_success
  assert_output --partial "[FOUND]"
  assert_link_exists "lib/tags/ByHash/$hash.png"
  run processURI 0000000000000000000000000000000000000000
  assert_failure
  assert_output --partial "[NOHASH]"
}

@test "local failures: NOFILE, UNREADABLE, NOTIMAGE, UNSUPPORTED, BADIMAGE" {
  run processURI missing.jpg
  assert_failure
  assert_output --partial "[NOFILE]"

  cp "$DATA/plasma.png" locked.png
  chmod 000 locked.png
  run processURI locked.png
  assert_output --partial "[UNREADABLE]"

  run processURI "$DATA/not-an-image.jpg"
  assert_output --partial "[NOTIMAGE] Not an image (text/html)"

  printf '<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"/>' > pic.svg
  run processURI pic.svg
  assert_output --partial "[UNSUPPORTED] SVG images are not supported"

  convert "$DATA/plasma.png" whole.jpg
  head -c 3000 whole.jpg > cut.jpg
  run processURI cut.jpg
  assert_output --partial "[BADIMAGE]"
  assert_no_temp_files
}

@test "relative paths resolve against a base folder" {
  mkdir sub
  cp "$DATA/plasma.png" sub/pic.png
  run processURI pic.png "$TEST_SANDBOX/sub"
  assert_success
  assert_output --partial "[ADDED]"
}

# --- URLs ------------------------------------------------------------

@test "a URL image is ADDED, whatever its URL looks like" {
  startServer
  cp "$DATA/plasma.png" www/picture
  run processURI "$URL/picture?utm_source=test"
  assert_success
  assert_output --partial "[ADDED]"
  run find lib/images -name '*.png'
  assert_output --regexp '\.png$'
  assert_no_temp_files
}

@test "URL failures: NOTFOUND, NOTIMAGE, UNREACHABLE, UNSUPPORTED" {
  startServer
  cp "$DATA/not-an-image.jpg" www/login.jpg
  run processURI "$URL/missing.jpg"
  assert_failure
  assert_output --partial "[NOTFOUND] HTTP 404"
  run processURI "$URL/login.jpg"
  assert_output --partial "[NOTIMAGE]"
  run processURI "https://sil-test.invalid/a.jpg"
  assert_output --partial "[UNREACHABLE]"
  run processURI "ftp://example.com/a.jpg"
  assert_output --partial "[UNSUPPORTED]"
  assert_no_temp_files
}

# --- summary ---------------------------------------------------------

@test "outcomeSummary counts successes and failures" {
  processURI "$DATA/plasma.png" 2> /dev/null || true
  processURI "$DATA/plasma.png" 2> /dev/null || true
  processURI missing.jpg 2> /dev/null || true
  run outcomeSummary
  assert_output --partial "Done: 1 ADDED, 1 DUPE"
  assert_output --partial "1 failed: 1 NOFILE"
}

# --- sources and date tags -------------------------------------------

@test "a new image gets today's date tag; a DUPE does not" {
  _silToday=2026-10-31
  processURI "$DATA/plasma.png" 2> /dev/null
  run find lib/tags/Date -type l
  assert_output --regexp '2026-10-31/[0-9a-f]{40}\.png$'
  _silToday=2026-11-01
  processURI "$DATA/plasma.png" 2> /dev/null
  assert_dir_not_exists lib/tags/Date/2026/2026-11-01
}

@test "sources: one line per distinct source, local files without folders" {
  mkdir -p a b
  cp "$DATA/plasma.png" a/pic.png
  cp "$DATA/plasma.png" b/pic.png
  cp "$DATA/plasma.png" other.png
  processURI a/pic.png 2> /dev/null
  processURI b/pic.png 2> /dev/null
  processURI other.png 2> /dev/null
  local hash
  hash="$(sha1sum "$DATA/plasma.png" | cut -c1-40)"
  run grep -v '^#' lib/images/sources.txt
  assert_output "$hash file:other.png
$hash file:pic.png"
}

@test "sources: URLs are recorded as given, a DUPE's too" {
  startServer
  cp "$DATA/plasma.png" www/one
  convert "$DATA/plasma.png" -resize 50% www/two
  processURI "$URL/one?x=1" 2> /dev/null
  processURI "$URL/two" 2> /dev/null
  processURI "$URL/one?x=1" 2> /dev/null
  run grep -v '^#' lib/images/sources.txt
  assert_equal "${#lines[@]}" 2
  assert_line --partial " $URL/one?x=1"
  assert_line --partial " $URL/two"
}

# --- known sources (REFETCH) -----------------------------------------

@test "a URL already recorded is a DUPE without downloading" {
  startServer
  cp "$DATA/plasma.png" www/pic
  processURI "$URL/pic" 2> /dev/null
  ## Gone from the server: a download would now be NOTFOUND
  rm www/pic
  SIL_TAG=Again
  run processURI "$URL/pic"
  assert_success
  assert_output --partial "[DUPE]"
  assert_output --partial "not downloaded"
  run find lib/tags/Again -type l
  assert_output --regexp '\.png$'
  run grep -c "GET /pic" server.log
  assert_output 1
}

@test "REFETCH downloads a recorded URL again" {
  startServer
  cp "$DATA/plasma.png" www/pic
  processURI "$URL/pic" 2> /dev/null
  SIL_REFETCH=1
  run processURI "$URL/pic"
  assert_output --partial "[DUPE]"
  assert_output --partial "0 of 256 bits differ"
  rm www/pic
  run processURI "$URL/pic"
  assert_output --partial "[NOTFOUND]"
}

@test "a recorded source whose image is gone is downloaded again" {
  startServer
  cp "$DATA/plasma.png" www/pic
  sourceAdd 0123456789abcdef0123456789abcdef01234567 "$URL/pic"
  run processURI "$URL/pic"
  assert_output --partial "[ADDED]"
}

@test "local files are always fingerprinted, even with a recorded name" {
  mkdir a b
  cp "$DATA/plasma.png" a/pic.png
  convert -size 320x240 -seed 99 plasma:fractal b/pic.png
  processURI a/pic.png 2> /dev/null
  run processURI b/pic.png
  assert_output --partial "[ADDED]"
}

# --- REMOVE and UNTAG --------------------------------------------------


@test "REMOVE by hash removes the image: REMOVED" {
  processURI "$DATA/plasma.png" 2> /dev/null
  local hash="$_silLastHash"
  SIL_REMOVE=1
  run processURI "$hash"
  assert_success
  assert_output --partial "[REMOVED] ${hash:0:12}"
  run findStoredImage "$hash"
  assert_failure
  run processURI "$hash"
  assert_failure
  assert_output --partial "[NOHASH]"
}

@test "REMOVE by known URL never downloads; the URL can then be added again" {
  startServer
  cp "$DATA/plasma.png" www/pic
  processURI "$URL/pic" 2> /dev/null
  SIL_REMOVE=1
  run processURI "$URL/pic"
  assert_output --partial "[REMOVED]"
  run grep -c "GET /pic" server.log
  assert_output 1
  run processURI "$URL/pic"
  assert_failure
  assert_output --partial "[NOTSTORED]"
  SIL_REMOVE=0
  run processURI "$URL/pic"
  assert_output --partial "[ADDED]"
}

@test "REMOVE by local file needs the identical stored file" {
  processURI "$DATA/plasma.png" 2> /dev/null
  convert "$DATA/plasma.png" -resize 50% half.png
  SIL_REMOVE=1
  run processURI half.png
  assert_failure
  assert_output --partial "[NOTSTORED]"
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "[REMOVED]"
}

@test "UNTAG removes tags from a known image, alongside TAG" {
  processURI "$DATA/plasma.png" 2> /dev/null
  SIL_TAG=Old
  processURI "$DATA/plasma.png" 2> /dev/null
  SIL_TAG=New
  SIL_UNTAG=Old
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "[FOUND]"
  assert_output --partial "Tagged: New"
  assert_output --partial "Untagged: Old"
  assert_not_exists lib/tags/Old
  assert_dir_exists lib/tags/New
}

@test "a new image without tags is Untagged; tagging it later removes that" {
  processURI "$DATA/plasma.png" 2> /dev/null
  local hash="$_silLastHash"
  assert_link_exists "lib/tags/Untagged/$hash.png"
  SIL_TAG=Dog
  run processURI "$DATA/plasma.png"
  assert_output --partial "[DUPE]"
  assert_not_exists lib/tags/Untagged
  assert_link_exists "lib/tags/Dog/$hash.png"
  ## TAG= keeps earlier tags, and doesn't make the image Untagged
  SIL_TAG=
  processURI "$DATA/plasma.png" 2> /dev/null
  assert_not_exists lib/tags/Untagged
  assert_link_exists "lib/tags/Dog/$hash.png"
}

@test "a new image with tags is not Untagged" {
  SIL_TAG=Dog
  processURI "$DATA/plasma.png" 2> /dev/null
  assert_link_exists "lib/tags/Dog/$_silLastHash.png"
  assert_not_exists lib/tags/Untagged
}

@test "TAG=New UNTAG=* replaces every tag" {
  SIL_TAG="Old, Older"
  processURI "$DATA/plasma.png" 2> /dev/null
  SIL_TAG=New
  SIL_UNTAG='*'
  run processURI "$DATA/plasma.png"
  assert_success
  assert_output --partial "Untagged: Old, Older"
  assert_output --partial "Tagged: New"
  assert_not_exists lib/tags/Old
  assert_not_exists lib/tags/Untagged
  assert_link_exists "lib/tags/New/$_silLastHash.png"
}

@test "UNTAG never adds an unknown image" {
  SIL_UNTAG=Any
  run processURI "$DATA/plasma.png"
  assert_failure
  assert_output --partial "[NOTSTORED]"
  run find lib/images -name '*.png'
  assert_output ""
}
