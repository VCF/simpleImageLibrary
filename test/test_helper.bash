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

# Common Sandbox Hook: Isolate file generation side-effects, and keep the real
# ~/.sil.conf from affecting tests
setup_sandbox() {
  TEST_SANDBOX="$(mktemp -d -t bats-sandbox.XXXXXX)"
  export TEST_SANDBOX
  export HOME="$TEST_SANDBOX/home"
  mkdir -p "$HOME"
  cd "$TEST_SANDBOX" || exit 1
}

teardown_sandbox() {
  if [[ -d "${TEST_SANDBOX:-}" && "${TEST_SANDBOX}" == *bats-sandbox* ]]; then
    rm -rf "$TEST_SANDBOX"
  fi
}

# Turn a library into one from before the layout file (image layout 1, see
# REQ-05): each image moved into an images/xx/yy/ folder, every tag link
# pointed at its new place, and the layout file removed.
# Arguments:
#   $1 - Library folder
toLayout1() {
  local lib="$1" f name old link
  local -a files links
  rm -f "$lib/images/layout.txt"
  mapfile -t files < <(find "$lib/images" -mindepth 2 -maxdepth 2 -type f)
  for f in "${files[@]}"; do
    name="${f##*/}"
    mkdir -p "$lib/images/${name:0:2}/${name:2:2}"
    mv "$f" "$lib/images/${name:0:2}/${name:2:2}/$name"
  done
  mapfile -t links < <(find "$lib/tags" -type l)
  for link in "${links[@]}"; do
    name="${link##*/}"
    old="$lib/images/${name:0:2}/${name:2:2}/$name"
    [[ -f "$old" ]] || continue
    ln -sfn "$(realpath -ms --relative-to="${link%/*}" "$old")" "$link"
  done
}

# List every stored image by file name and content hash, whatever folder
# holds it, so the same images in another layout list the same.
# Arguments:
#   $1 - Library folder
imageMap() {
  find "$1/images" -mindepth 2 -type f -exec sha1sum {} + \
    | awk '{ n = $2; sub(/.*\//, "", n); print n, $1 }' | LC_ALL=C sort
}

# List every tag link with the name of what it reaches, or BROKEN, so the
# same tags in another image layout list the same.
# Arguments:
#   $1 - Library folder
linkMap() {
  local link target
  find "$1/tags" -type l | LC_ALL=C sort | while IFS= read -r link; do
    target="$(readlink -e "$link")" || target=BROKEN
    printf '%s -> %s\n' "${link#"$1"/}" "${target##*/}"
  done
}
