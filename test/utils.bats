#!/usr/bin/env bats
## Tests for src/utils.sh

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
