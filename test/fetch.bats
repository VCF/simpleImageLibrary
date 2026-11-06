#!/usr/bin/env bats
## Tests for src/fetch.sh, with stand-ins for curl and torsocks: what is sent to
## them (REQ-04), and how their failures are reported (REQ-08). See ingest.bats
## for real downloads from a local web server

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
  CURL_STATUS=0
  CURL_CODE=404
}

teardown() {
  teardown_sandbox
}

## Stand-in curl: notes its arguments, one per line, then ends with
## CURL_STATUS, reporting CURL_CODE as the HTTP status
# shellcheck disable=SC2317  # Called by fetchURL
curl() {
  printf '%s\n' "$@" > "$TEST_SANDBOX/curl.args"
  (( CURL_STATUS == 0 )) || echo "curl: stand-in failure" >&2
  printf '%s' "$CURL_CODE"
  return "$CURL_STATUS"
}

## Stand-in torsocks: notes that it was used, then runs its command
# shellcheck disable=SC2317  # Called by fetchURL
torsocks() {
  touch "$TEST_SANDBOX/torsocks.used"
  "$@"
}

# --- what is sent (REQ-04) ---------------------------------------------

@test "requests send the generic User-Agent, and time limits" {
  run processURI https://example.com/a.jpg
  run grep -Fx -A1 -- --user-agent curl.args
  assert_line --index 1 "$_silUserAgent"
  [[ "$_silUserAgent" != *[Ss][Ii][Ll]* ]]
  run grep -Fx -A1 -- --connect-timeout curl.args
  assert_line --index 1 30
  run grep -Fx -A1 -- --max-time curl.args
  assert_line --index 1 300
}

@test "ordinary URLs don't use Tor, even if .onion appears outside the host" {
  local url
  for url in https://example.com/a.jpg https://example.com/x.onion \
    "https://example.com/?u=a.onion" https://onion.example.com/a.jpg; do
    run processURI "$url"
    assert_not_exists torsocks.used
  done
}

@test ".onion addresses always go through Tor" {
  local url
  for url in http://abc.onion/a.jpg HTTP://ABC.ONION/a.jpg \
    http://abc.onion:8080/a.jpg http://me@abc.onion/a.jpg "http://abc.onion?x=1"; do
    rm -f torsocks.used
    run processURI "$url"
    assert_exists torsocks.used
  done
}

@test "TOR sends every URL through Tor; TOR=off doesn't" {
  SIL_TOR=1
  run processURI https://example.com/a.jpg
  assert_exists torsocks.used
  rm torsocks.used
  SIL_TOR=0
  run processURI https://example.com/a.jpg
  assert_not_exists torsocks.used
}

@test "TOR doesn't apply to local files" {
  SIL_TOR=1
  run processURI "$PROJECT_ROOT/test/data/images/plasma.png"
  assert_success
  assert_output --partial "[ADDED]"
  assert_not_exists torsocks.used
}

@test "without torsocks, a Tor download halts rather than going direct" {
  unset -f torsocks
  local realPath="$PATH"
  # shellcheck disable=SC2123  # Deliberate: no command can be found
  PATH="$TEST_SANDBOX/no-tools"
  run fetchURL http://abc.onion/a.jpg dest
  PATH="$realPath"
  assert_failure 1
  assert_output --partial "Required tool 'torsocks' is not installed"
  assert_output --partial "sudo apt install torsocks"
  assert_not_exists curl.args
}

# --- how failures are reported (REQ-08) --------------------------------

@test "HTTP errors have their own reasons" {
  local code expected
  while read -r code expected; do
    CURL_CODE="$code"
    run processURI https://example.com/a.jpg
    assert_failure
    assert_output --partial "[$expected]"
  done <<'END'
404 NOTFOUND
410 NOTFOUND
429 RATELIMIT
403 HTTPERROR
500 HTTPERROR
END
}

@test "curl failures are TIMEOUT or UNREACHABLE" {
  CURL_STATUS=28
  CURL_CODE=000
  run processURI https://example.com/a.jpg
  assert_failure
  assert_output --partial "[TIMEOUT] No response in time"
  CURL_STATUS=7
  run processURI https://example.com/a.jpg
  assert_failure
  assert_output --partial "[UNREACHABLE] curl: stand-in failure"
}

@test "curl failures through Tor are TORFAIL, except a timeout" {
  CURL_CODE=000
  CURL_STATUS=7
  run processURI http://abc.onion/a.jpg
  assert_failure
  assert_output --partial "[TORFAIL] Failed through Tor; is Tor running?"
  CURL_STATUS=28
  run processURI http://abc.onion/a.jpg
  assert_output --partial "[TIMEOUT]"
}

@test "failed downloads leave no temp files" {
  run processURI https://example.com/a.jpg
  run find lib/.tmp -type f
  assert_output ""
}
