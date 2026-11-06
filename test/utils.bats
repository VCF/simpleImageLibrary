#!/usr/bin/env bats
## Tests for src/utils.sh

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
}

@test "setTilda replaces a leading HOME only" {
  HOME=/home/me
  run setTilda "/home/me/pics/home/me"
  # shellcheck disable=SC2088  # Literal tilde is the expected output
  assert_output "~/pics/home/me"
  run setTilda "/other/home/me"
  assert_output "/other/home/me"
}

@test "setTilda with custom prefix and replacement containing &" {
  run setTilda "/lib/a.jpg" "/lib" "A&B"
  assert_output "A&B/a.jpg"
}

@test "relativePath: child, same, trailing slashes" {
  run relativePath /lib /lib/images/f1
  assert_output "images/f1"
  run relativePath /lib/ /lib/
  assert_output "."
}

@test "relativePath backs up for tag symlink targets" {
  run relativePath /lib/tags/Animal/Dog /lib/images/f1/d2/f1d2.jpg
  assert_output "../../../images/f1/d2/f1d2.jpg"
}

@test "msgError halts with status 1" {
  run msgError "boom"
  assert_failure 1
  assert_output --partial "boom"
}

@test "messages have their colors, and go to STDERR only" {
  local fn code
  while read -r fn code; do
    run --separate-stderr "$fn" "text"
    assert_equal "$output" ""
    [[ "$stderr" == *$'\033[1;'"$code"m* ]]
    [[ "$stderr" == *text* ]]
  done <<EOF
msgInfo $FgBlue
msgWarn $FgRed
msgError $BgYellow;$FgRed
msgDebug $BgCyan;$FgMagenta
EOF
}

@test "msgError runs the halt hook once, with its message, before halting" {
  # shellcheck disable=SC2317 # called by msgError
  noteHalt() { echo "hook saw: $1 [${_silHaltHook}]"; }
  _silHaltHook=noteHalt
  run msgError "boom"
  assert_failure 1
  assert_output --partial "hook saw: boom []"
}

@test "requireTool passes for present tools, halts with install hint" {
  requireTool bash bash "test"
  run requireTool no-such-tool-xyz some-pkg "do things"
  assert_failure
  assert_output --partial "sudo apt install some-pkg"
  assert_output --partial "do things"
}

@test "humanSize formats bytes" {
  run humanSize 500
  assert_output "500 B"
  run humanSize 512000
  assert_output "500.0 KB"
  run humanSize 1572864
  assert_output "1.5 MB"
}

@test "msgStatus shows only on a terminal; the next message overwrites it" {
  _silStatusTty=0
  run msgStatus "Working"
  assert_output ""
  _silStatusTty=1
  run msgStatus "Working"
  assert_output --partial $'\r\033[K'
  assert_output --partial "Working"
  refute_output --partial $'\n'
  run msgInfo "Done"
  assert_output --regexp $'^\r\033\\[K'
}
