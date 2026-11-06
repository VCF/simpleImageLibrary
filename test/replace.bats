#!/usr/bin/env bats
## Tests for src/replace.sh (KEEPLARGER)

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
  srcLib "maintain"
  resetParams
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  DATA="$PROJECT_ROOT/test/data/images"
  ## small.png is plasma.png; big.png is the same picture at twice the size
  cp "$DATA/plasma.png" small.png
  convert small.png -resize 200% big.png
  SMALL="$(fileHash small.png)"
  BIG="$(fileHash big.png)"
  _silToday=2026-10-31
}

teardown() {
  teardown_sandbox
}

## Add small.png, then offer big.png with KEEPLARGER set
upgrade() {
  processURI small.png 2> /dev/null
  _silToday=2026-11-06
  SIL_KEEPLARGER=1
  processURI big.png 2> /dev/null
}

# --- when it replaces ------------------------------------------------

@test "without KEEPLARGER a larger duplicate is a DUPE, changing nothing" {
  processURI small.png 2> /dev/null
  run processURI big.png
  assert_output --partial "[DUPE]"
  assert_exists "$(storedImagePath "$SMALL" png)"
  assert_not_exists lib/ReplacedImages.tsv
  assert_not_exists lib/replacedWithHigherRes
}

@test "a larger duplicate replaces the stored image" {
  processURI small.png 2> /dev/null
  SIL_KEEPLARGER=1
  run processURI big.png
  assert_success
  assert_output --partial "[UPGRADED] ${BIG:0:12} - replaced ${SMALL:0:12} (320x240 -> 640x480,"
  assert_exists "$(storedImagePath "$BIG" png)"
  assert_not_exists "$(storedImagePath "$SMALL" png)"
  assert_files_equal "lib/replacedWithHigherRes/$SMALL.png" small.png
}

@test "a duplicate of the same or smaller size is a DUPE" {
  processURI big.png 2> /dev/null
  SIL_KEEPLARGER=1
  run processURI small.png
  assert_output --partial "[DUPE] ${BIG:0:12}"
  convert big.png -resize 640x480! -quality 50 same.jpg
  run processURI same.jpg
  assert_output --partial "[DUPE] ${BIG:0:12}"
  assert_not_exists lib/ReplacedImages.tsv
}

@test "a fingerprint is replaced in the index, leaving the library consistent" {
  upgrade
  run grep -c "^$SMALL " lib/images/fingerprints.txt
  assert_output 0
  run grep -c "^$BIG " lib/images/fingerprints.txt
  assert_output 1
  run libraryCheck
  assert_success
}

# --- what moves ------------------------------------------------------

@test "tags move to the replacement, which keeps the old date" {
  SIL_TAG=Animal/Dog
  processURI small.png 2> /dev/null
  SIL_TAG=Other
  _silToday=2026-11-06
  SIL_KEEPLARGER=1
  processURI big.png 2> /dev/null
  [[ -e "lib/tags/Animal/Dog/$BIG.png" ]]
  [[ -e "lib/tags/Other/$BIG.png" ]]
  [[ ! -L "lib/tags/Animal/Dog/$SMALL.png" ]]
  [[ -e "lib/tags/Date/2026/2026-10-31/$BIG.png" ]]
  assert_dir_not_exists lib/tags/Date/2026/2026-11-06
}

@test "an Untagged image stays Untagged, unless now given a tag" {
  upgrade
  [[ -e "lib/tags/Untagged/$BIG.png" ]]
  convert small.png -resize 300% bigger.png
  SIL_TAG=Now
  processURI bigger.png 2> /dev/null
  local hash
  hash="$(fileHash bigger.png)"
  [[ -e "lib/tags/Now/$hash.png" ]]
  assert_dir_not_exists lib/tags/Untagged
}

@test "sources move to the replacement, which adds its own" {
  upgrade
  run grep -v '^#' lib/images/sources.txt
  assert_output "$BIG file:big.png
$BIG file:small.png"
  run sourceLookup file:small.png
  assert_output "$BIG"
}

# --- the log ---------------------------------------------------------

@test "the log has a header, then one tab-separated line" {
  upgrade
  local bits
  bits="$(fingerprintDistance "$(imageFingerprint small.png)" "$(imageFingerprint big.png)")"
  run cat lib/ReplacedImages.tsv
  assert_line --index 0 "$(printf 'date\toldHash\tnewHash\toldWxH\tnewWxH\tbitsDiffering\tlowResURL\thighResURL')"
  assert_line --index 1 "$(printf '2026-11-06\t%s\t%s\t320x240\t640x480\t%s\tfile:small.png\tfile:big.png' "$SMALL" "$BIG" "$bits")"
  assert_equal "${#lines[@]}" 2
}

@test "an image with several sources is logged once per source" {
  processURI small.png 2> /dev/null
  cp small.png again.png
  processURI again.png 2> /dev/null
  SIL_KEEPLARGER=1
  processURI big.png 2> /dev/null
  run cut -f7 lib/ReplacedImages.tsv
  assert_output "lowResURL
file:again.png
file:small.png"
}

@test "an image with no sources is logged with a dash" {
  storeImage small.png stored
  SIL_KEEPLARGER=1
  processURI big.png 2> /dev/null
  run cut -f7 lib/ReplacedImages.tsv
  assert_line --index 1 "-"
}

@test "further replacements add to the log, keeping one header" {
  upgrade
  convert small.png -resize 300% bigger.png
  processURI bigger.png 2> /dev/null
  run grep -c '^date' lib/ReplacedImages.tsv
  assert_output 1
  ## The first replacement moved two sources to the image the second replaced
  run wc -l lib/ReplacedImages.tsv
  assert_output --partial "4 "
}

# --- still and animated ----------------------------------------------

@test "a larger still does not replace an animation" {
  processURI "$DATA/animated.gif" 2> /dev/null
  local frame
  frame="$(silMktemp .png)"
  fingerprintFrame "$DATA/animated.gif" "$frame"
  convert "$frame" -resize 300% still.png
  rm "$frame"
  SIL_KEEPLARGER=1
  run processURI still.png
  assert_output --partial "[DUPE]"
  assert_output --partial "one is animated and the other still"
  assert_not_exists lib/ReplacedImages.tsv
}

@test "a larger animation does not replace a still" {
  local frame
  frame="$(silMktemp .png)"
  fingerprintFrame "$DATA/animated.gif" "$frame"
  cp "$frame" still.png
  rm "$frame"
  processURI still.png 2> /dev/null
  convert "$DATA/animated.gif" -coalesce -resize 300% bigger.gif
  SIL_KEEPLARGER=1
  run processURI bigger.gif
  assert_output --partial "[DUPE]"
  assert_output --partial "one is animated and the other still"
  assert_not_exists lib/ReplacedImages.tsv
}

@test "a larger animation replaces an animation" {
  processURI "$DATA/animated.gif" 2> /dev/null
  convert "$DATA/animated.gif" -coalesce -resize 200% bigger.gif
  SIL_KEEPLARGER=1
  run processURI bigger.gif
  assert_output --partial "[UPGRADED]"
  assert_output --partial "(120x120 -> 240x240,"
}

# --- other cases -----------------------------------------------------

@test "a match with the same file stored separately replaces nothing" {
  storeImage small.png stored
  storeImage big.png stored
  sourceAdd "$SMALL" small.png
  _silOutcomeHash="$SMALL"
  SIL_KEEPLARGER=1
  keepLarger big.png "$(imageFingerprint big.png)" 2 big.png
  assert_equal "$_silOutcome" DUPE
  assert_equal "$_silOutcomeHash" "$BIG"
  assert_exists "$(storedImagePath "$SMALL" png)"
  assert_not_exists lib/ReplacedImages.tsv
}

@test "if the log can't be written, the library is left unchanged" {
  processURI small.png 2> /dev/null
  mkdir lib/ReplacedImages.tsv
  SIL_KEEPLARGER=1
  run processURI big.png
  assert_failure
  assert_output --partial "[STOREFAIL]"
  assert_exists "$(storedImagePath "$SMALL" png)"
  assert_not_exists "$(storedImagePath "$BIG" png)"
  assert_not_exists "lib/replacedWithHigherRes/$SMALL.png"
  rmdir lib/ReplacedImages.tsv
  run libraryCheck
  assert_success
}

@test "a replacement that stops part way is STOREFAIL, pointing to CHECK" {
  processURI small.png 2> /dev/null
  # shellcheck disable=SC2317 # stand-in, called by replaceStored
  indexRemove() { return 1; }
  SIL_KEEPLARGER=1
  run processURI big.png
  assert_failure
  assert_output --partial "[STOREFAIL] Replacing ${SMALL:0:12} with ${BIG:0:12} did not finish; see sil CHECK"
  ## Nothing is lost: the old image is still there, and saved
  assert_exists "$(storedImagePath "$SMALL" png)"
  assert_files_equal "lib/replacedWithHigherRes/$SMALL.png" small.png
}

@test "a larger duplicate is shrunk before it replaces the stored image" {
  processURI small.png 2> /dev/null
  SIL_KEEPLARGER=1
  SIL_SHRINK=51200
  run processURI big.png
  assert_success
  assert_output --partial "[UPGRADED]"
  assert_output --partial "(320x240 -> 640x480,"
  run find lib/images -name '*.jpg'
  assert_equal "${#lines[@]}" 1
  assert_not_exists "$(storedImagePath "$SMALL" png)"
  run libraryCheck
  assert_success
}

@test "REFETCH of a known URL can upgrade its image" {
  ## A stand-in download: the site now serves a larger copy
  # shellcheck disable=SC2317 # stand-in, called by fetchURI
  fetchURL() { cp big.png "$2"; }
  processURI small.png 2> /dev/null
  sourceAdd "$SMALL" https://example.com/pic
  SIL_KEEPLARGER=1
  run processURI https://example.com/pic
  assert_output --partial "[DUPE] ${SMALL:0:12} - known source"
  SIL_REFETCH=1
  run processURI https://example.com/pic
  assert_output --partial "[UPGRADED] ${BIG:0:12}"
  run sourceLookup https://example.com/pic
  assert_output "$BIG"
}

@test "new libraries already ignore the replaced folder" {
  assert_file_contains lib/.gitignore '^replacedWithHigherRes/$'
  assert_file_contains lib/.gitattributes '^ReplacedImages.tsv merge=union$'
}

@test "older libraries gain the git settings at their first replacement" {
  printf '.tmp/' > lib/.gitignore
  : > lib/.gitattributes
  upgrade
  convert small.png -resize 300% bigger.png
  processURI bigger.png 2> /dev/null
  run cat lib/.gitignore
  assert_output ".tmp/
replacedWithHigherRes/"
  run cat lib/.gitattributes
  assert_output "ReplacedImages.tsv merge=union"
}

@test "UPGRADED is a success with a report legend" {
  isSuccessTag UPGRADED
  srcLib "report"
  [[ -n "${_silOutcomeMeaning[UPGRADED]}" ]]
}
