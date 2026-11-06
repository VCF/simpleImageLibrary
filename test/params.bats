#!/usr/bin/env bats
## Tests for src/params.sh

# Each bats test runs in its own subshell, which is intended
# shellcheck disable=SC2030,SC2031

load test_helper

setup() {
  setup_sandbox
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  resetParams
}

teardown() {
  teardown_sandbox
}

# --- helpers ---------------------------------------------------------

@test "trim strips surrounding whitespace only" {
  run trim $'  \tMeme / Politics \t '
  assert_output "Meme / Politics"
}

@test "unquote strips one matching pair of quotes" {
  run unquote "'Meme/Politics'"
  assert_output "Meme/Politics"
  run unquote '"a b"'
  assert_output "a b"
  run unquote "'mismatched\""
  assert_output "'mismatched\""
}

# --- name resolution -------------------------------------------------

@test "paramCanonical is case-insensitive and resolves aliases" {
  run paramCanonical tag
  assert_output "TAG"
  run paramCanonical TaGs
  assert_output "TAG"
  run paramCanonical usetor
  assert_output "TOR"
}

@test "paramCanonical fails on unknown or empty names" {
  run paramCanonical bogus
  assert_failure
  run paramCanonical ""
  assert_failure
}

@test "isParamToken accepts params and rejects URIs and paths" {
  isParamToken "TOR"
  isParamToken "tag=Meme"
  isParamToken "TAG = Meme"
  run isParamToken "https://example.com/a.jpg?tag=1"
  assert_failure
  run isParamToken "./TOR"
  assert_failure
  run isParamToken "f1d2d2f924e986ac86fdf7b36c94bcdf32beec15"
  assert_failure
}

# --- setting values --------------------------------------------------

@test "setParamToken sets value parameters, trimmed and unquoted" {
  setParamToken "tags = 'Humor , Politics/Humor' "
  assert_equal "$SIL_TAG" "Humor , Politics/Humor"
}

@test "repeating a parameter replaces its value" {
  setParamToken "TAG=Meme"
  setParamToken "tags=Politics"
  assert_equal "$SIL_TAG" "Politics"
}

@test "setParamToken keeps '=' inside values" {
  setParamToken "LINK=a=b"
  assert_equal "$SIL_LINK" "a=b"
}

@test "flags: bare, any value, and zero" {
  setParamToken "TOR"
  assert_equal "$SIL_TOR" 1
  setParamToken "TOR=0"
  assert_equal "$SIL_TOR" 0
  setParamToken "usetor=yes"
  assert_equal "$SIL_TOR" 1
}

@test "flags: no, false and off unset, any case" {
  local v
  for v in no NO false False off OFF; do
    setParamToken "TOR"
    setParamToken "TOR=$v"
    assert_equal "$SIL_TOR" 0
  done
}

@test "flagIsSet reflects flag state" {
  setParamToken "TOR=0"
  run flagIsSet TOR
  assert_failure
  setParamToken "TOR"
  flagIsSet usetor
}

@test "value parameter without a value halts" {
  run setParamToken "TAG"
  assert_failure
  assert_output --partial "requires a value"
}

@test "an empty value clears TAG and UNTAG, but halts for others" {
  setParamToken "TAG=Foo"
  setParamToken "TAG="
  assert_equal "$SIL_TAG" ""
  setParamToken "UNTAG=Foo"
  setParamToken "UNTAG = "
  assert_equal "$SIL_UNTAG" ""
  run setParamToken "LINK="
  assert_failure
  assert_output --partial "requires a value"
}

@test "unknown parameter warns and returns failure" {
  run setParamToken "BOGUS=1"
  assert_failure
  assert_output --partial "Unrecognized parameter 'BOGUS'"
}

@test "resetParams clears environment leakage and applies defaults" {
  SIL_TAG="leaked"
  resetParams
  assert_equal "${SIL_TAG+set}" ""
  assert_equal "$SIL_THRESHOLD" 90
  assert_equal "$SIL_TOR" 0
}

# --- typed values ----------------------------------------------------

@test "parseSize: units, case, decimals, bare kb" {
  local -A cases=(
    [500]=512000 [500k]=512000 [500KB]=512000 [500 kb]=512000
    [2mb]=2097152 [2M]=2097152 [1.5mb]=1572864 [1g]=1073741824
    [10b]=10 [0]=0 [08]=8192
  )
  local k
  for k in "${!cases[@]}"; do
    run parseSize "$k"
    assert_output "${cases[$k]}"
  done
}

@test "parseSize rejects junk" {
  local bad
  for bad in "" big 5tb -1 1.5.2 kb "5 k b"; do
    run parseSize "$bad"
    assert_failure
  done
}

@test "size parameter is stored in bytes" {
  setParamToken "shrink = '500kb'"
  assert_equal "$SIL_SHRINK" 512000
}

@test "percent parameters accept optional %, range 0-100" {
  setParamToken "SHRINKMINSAVE=30%"
  assert_equal "$SIL_SHRINKMINSAVE" 30
  setParamToken "THRESHOLD=098"
  assert_equal "$SIL_THRESHOLD" 98
  run setParamToken "THRESHOLD=101"
  assert_failure
  assert_output --partial "Invalid percent for THRESHOLD"
}

@test "number parameters accept positive decimals only" {
  setParamToken "SHRINKTRIGGER=1.5"
  assert_equal "$SIL_SHRINKTRIGGER" 1.5
  local bad
  for bad in 0 0.0 -2 two 1.; do
    run setParamToken "SHRINKTRIGGER=$bad"
    assert_failure
  done
}

@test "level parameters accept names and aliases in any case" {
  local -A cases=(
    [HIGH]=HIGH [hi]=HIGH [H]=HIGH
    [Medium]=MEDIUM [med]=MEDIUM [m]=MEDIUM
    [low]=LOW [Lo]=LOW [l]=LOW
    [off]=OFF [0]=OFF [No]=OFF [false]=OFF
  )
  local k
  for k in "${!cases[@]}"; do
    setParamToken "SHRINKVID=$k"
    assert_equal "$SIL_SHRINKVID" "${cases[$k]}"
  done
}

@test "level parameters reject other values, with examples" {
  run setParamToken "SHRINKVID=best"
  assert_failure
  assert_output --partial "Invalid level for SHRINKVID"
  assert_output --partial "HIGH, MEDIUM, LOW"
}

@test "SHRINKVID defaults to OFF" {
  assert_equal "$SIL_SHRINKVID" OFF
}

@test "invalid size halts with examples and source" {
  run setParamToken "SHRINK=huge" "my.conf line 3"
  assert_failure
  assert_output --partial "Expected eg: 500kb"
  assert_output --partial "my.conf line 3"
}

# --- command line ----------------------------------------------------

@test "parseCliParams splits params from URIs" {
  parseCliParams TAG=Meme TOR https://example.com/a.jpg local.jpg
  assert_equal "${_silCliParams[*]}" "TAG=Meme TOR"
  assert_equal "${_silArgs[*]}" "https://example.com/a.jpg local.jpg"
}

@test "parseCliParams halts on a parameter after a URI" {
  run parseCliParams https://example.com/a.jpg TAG=Meme
  assert_failure
  assert_output --partial "follows a URI"
}

@test "parseCliParams halts on a misspelled parameter" {
  run parseCliParams TAGG=Meme a.jpg
  assert_failure
  assert_output --partial "Unrecognized parameter 'TAGG'"
}

@test "parseCliParams ignores STOPSIL with a warning" {
  run parseCliParams stopsil TAG=Meme a.jpg
  assert_success
  assert_output --partial "STOPSIL only applies in a manifest - ignored"
  parseCliParams stopsil TAG=Meme a.jpg 2> /dev/null
  assert_equal "${_silCliParams[*]}" "TAG=Meme"
  assert_equal "${_silArgs[*]}" "a.jpg"
}

@test "parseCliParams treats an existing NAME=x file as a URI" {
  touch "weird=name.jpg"
  parseCliParams "weird=name.jpg"
  assert_equal "${_silArgs[*]}" "weird=name.jpg"
}

# --- files and precedence --------------------------------------------

@test "parseParamFile skips comments and blanks, warns on junk" {
  cat > conf <<'EOF'
# comment

  shrink = "500kb"
not a param
TOR
EOF
  run parseParamFile conf
  assert_failure
  assert_output --partial "conf line 4"
  parseParamFile conf || true
  assert_equal "$SIL_SHRINK" 512000
  assert_equal "$SIL_TOR" 1
}

@test "TAG, UNTAG, REMOVE, LINK and REMAP are ignored with a warning in any conf file" {
  printf 'tags=Bird\nLINK=a -> b\nREMAP=c -> d\nUNTAG=Fish\nREMOVE\nTHRESHOLD=95\n' > conf
  local kind name
  for kind in global library; do
    run parseParamFile conf "$kind"
    assert_failure
    for name in TAG LINK REMAP UNTAG REMOVE; do
      assert_output --partial "$name can't be set in a configuration file"
    done
    assert_output --partial "conf line 1"
  done
  parseParamFile conf global || true
  assert_equal "${SIL_TAG+set}" ""
  assert_equal "${SIL_LINK+set}" ""
  assert_equal "${SIL_REMAP+set}" ""
  assert_equal "${SIL_UNTAG+set}" ""
  assert_equal "$SIL_REMOVE" 0
  assert_equal "$SIL_THRESHOLD" 95
}

@test "LIBRARY is allowed in ~/.sil.conf only" {
  printf 'LIBRARY=/some/lib\n' > conf
  parseParamFile conf global
  assert_equal "$SIL_LIBRARY" /some/lib
  unset SIL_LIBRARY
  run parseParamFile conf library
  assert_failure
  assert_output --partial "only read once the library is known"
  parseParamFile conf || true
  assert_equal "${SIL_LIBRARY+set}" ""
}

@test "parseParamFile handles a missing final newline" {
  printf 'THRESHOLD=77' > conf
  parseParamFile conf
  assert_equal "$SIL_THRESHOLD" 77
}

@test "loadParams precedence: cli > library conf > global conf" {
  mkdir lib
  printf 'SHRINKMINSAVE=10\nTHRESHOLD=80%%\nSHRINKTRIGGER=3\nLIBRARY=%s\n' \
    "$TEST_SANDBOX/lib" > "$HOME/.sil.conf"
  printf 'SHRINKMINSAVE=20\nTHRESHOLD=95%%\n' > lib/sil.conf
  loadParams SHRINKMINSAVE=30 a.jpg
  loadLibraryParams
  assert_equal "$SIL_SHRINKMINSAVE" 30
  assert_equal "$SIL_THRESHOLD" 95
  assert_equal "$SIL_SHRINKTRIGGER" 3
  assert_equal "${_silArgs[*]}" "a.jpg"
}

@test "loadParams: command line LIBRARY selects the library conf" {
  mkdir lib
  printf 'SHRINKMINSAVE=20\n' > lib/sil.conf
  loadParams LIBRARY=lib a.jpg
  loadLibraryParams
  assert_equal "$SIL_SHRINKMINSAVE" 20
}

@test "cliHasParam recognizes names and aliases in any case" {
  parseCliParams usetor library=x a.jpg
  cliHasParam TOR
  cliHasParam LIBRARY
  run cliHasParam TAG
  assert_failure
}

# --- template --------------------------------------------------------

@test "templates/sil.conf examples are all valid once uncommented" {
  sed 's/^# \([A-Za-z_]*=\)/\1/' "$PROJECT_ROOT/templates/sil.conf" > sil.conf
  run parseParamFile sil.conf
  assert_success
  refute_output --partial "[!]"
}

@test "templates/sil.conf has an example for every settable parameter" {
  local canon
  for canon in "${!_silParamType[@]}"; do
    [[ -n "${_silParamScope[$canon]:-}" ]] && continue
    grep -q "^# $canon=" "$PROJECT_ROOT/templates/sil.conf" \
      || fail "No example for $canon in templates/sil.conf"
  done
}

@test "loadParams continues past ignored conf lines" {
  printf 'TAG=Bird\nTHRESHOLD=70\n' > "$HOME/.sil.conf"
  loadParams TAG=cli a.jpg
  assert_equal "$SIL_TAG" "cli"
  assert_equal "$SIL_THRESHOLD" 70
}

@test "showParams aligns on '=' and leaves out LIBRARY" {
  SIL_LIBRARY=/some/lib
  SIL_TAG=Humor
  SIL_SHRINK=1024
  SIL_THRESHOLD=90
  run showParams
  refute_output --partial "LIBRARY"
  assert_output --partial " TAG = Humor"
  assert_output --partial " SHRINK = 1024 (1.0 KB)"
  ## Every '=' is in the same column
  run awk '{ print index($0, " = ") }' <<< "$output"
  assert_equal "$(sort -u <<< "$output" | wc -l)" 1
}
