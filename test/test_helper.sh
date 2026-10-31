#!/usr/bin/env bash

# Establish the project root path relative to this file
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# Resolve paths to vendored libraries
BATS_SUPPORT_DIR="${PROJECT_ROOT}/test/libs/bats-support"
BATS_ASSERT_DIR="${PROJECT_ROOT}/test/libs/bats-assert"
BATS_FILE_DIR="${PROJECT_ROOT}/test/libs/bats-file"

# Force load the helper frameworks
load "${BATS_SUPPORT_DIR}/load.bash"
load "${BATS_ASSERT_DIR}/load.bash"
load "${BATS_FILE_DIR}/load.bash"

# Common Sandbox Hook: Isolate file generation side-effects
setup_sandbox() {
  TEST_SANDBOX="$(mktemp -d -t bats-sandbox.XXXXXX)"
  export TEST_SANDBOX
  cd "$TEST_SANDBOX" || exit 1
}

teardown_sandbox() {
  if [[ -d "${TEST_SANDBOX:-}" && "${TEST_SANDBOX}" == *bats-sandbox* ]]; then
    rm -rf "$TEST_SANDBOX"
  fi
}
