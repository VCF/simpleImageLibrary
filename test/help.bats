#!/usr/bin/env bats
## Tests for src/help.sh and how sil.sh invokes it

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "help"
}

teardown() {
  teardown_sandbox
}

@test "sil shows help and succeeds with no arguments, -h and --help" {
  local args
  for args in "" "-h" "--help"; do
    # shellcheck disable=SC2086  # Empty args must expand to no argument
    run "$PROJECT_ROOT/sil" $args
    assert_success
    assert_output --partial "Usage:"
  done
}

@test "sil help is written to STDOUT, so that it can be piped" {
  # shellcheck disable=SC2016  # $0 is expanded by the inner shell
  run bash -c '"$0" --help 2> /dev/null' "$PROJECT_ROOT/sil"
  assert_success
  assert_output --partial "Usage:"
}

@test "sil --help anywhere shows help without acting on other arguments" {
  run "$PROJECT_ROOT/sil" LIBRARY=newlib TAG=Dog dog.jpg --help
  assert_success
  assert_output --partial "Usage:"
  assert_not_exists newlib
}

@test "sil treats ./-h as a file rather than a request for help" {
  run "$PROJECT_ROOT/sil" LIBRARY=lib ./-h
  assert_failure
  assert_output --partial "NOFILE"
  refute_output --partial "Usage:"
}

@test "showHelp lists every parameter and alias" {
  local helpText name
  helpText="$(showHelp)"
  for name in "${!_silParamType[@]}" "${!_silParamAlias[@]}"; do
    grep -qw "$name" <<< "$helpText" || fail "$name is not in the help"
  done
}

@test "showHelp fits in 80 columns" {
  run bash -c "$(declare -f showHelp); showHelp | awk 'length > 80'"
  assert_success
  assert_output ""
}

@test "README parameter table lists every parameter and alias" {
  local name
  for name in "${!_silParamType[@]}"; do
    grep -q "^| \`$name\`" "$PROJECT_ROOT/README.md" \
      || fail "No README table row for $name"
  done
  for name in "${!_silParamAlias[@]}"; do
    grep -qE "^\| .*\`$name\`" "$PROJECT_ROOT/README.md" \
      || fail "Alias $name is not in the README table"
  done
}
