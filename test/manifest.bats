#!/usr/bin/env bats
## Tests for src/manifest.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "manifest"
  srcLib "library"
  resetParams
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  mkdir -p work
  cp "$PROJECT_ROOT/test/data/images/plasma.png" \
    "$PROJECT_ROOT/test/data/images/animated.gif" work/
}

teardown() {
  teardown_sandbox
}

@test "parameters apply to the URIs after them; paths are manifest-relative" {
  cat > work/m.txt <<'EOF'
# comment

  tag = First
plasma.png
TAG=Second
animated.gif
EOF
  cd /
  run parseManifest "$TEST_SANDBOX/work/m.txt"
  assert_success
  cd "$TEST_SANDBOX"
  run find lib/tags/First lib/tags/Second -type l
  assert_line --partial "First/"
  assert_line --partial "Second/"
  assert_equal "${#lines[@]}" 2
}

@test "TAG= clears an earlier TAG; URIs are shown with line numbers" {
  printf 'TAG=First\nplasma.png\nTAG=\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "[2] plasma.png"
  assert_output --partial "[4] animated.gif"
  run find lib/tags/First lib/tags/Untagged -type l
  assert_line --regexp "First/.*\\.png$"
  assert_line --regexp "Untagged/.*\\.gif$"
  assert_equal "${#lines[@]}" 2
}

@test "settings are restored after the manifest" {
  SIL_TAG=Outer
  printf 'TAG=Inner\nTHRESHOLD=99\nplasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  assert_equal "$SIL_TAG" Outer
  assert_equal "$SIL_THRESHOLD" 90
}

@test "CHECK and REBUILD are ignored in a manifest" {
  printf 'CHECK\nREBUILD\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "CHECK can't be set in a manifest"
  assert_output --partial "REBUILD can't be set in a manifest"
  assert_output --partial "[ADDED]"
}

@test "STOPSIL ends the manifest at its line" {
  printf 'TAG=First\nplasma.png\nSTOPSIL\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "STOPSIL: rest of manifest skipped (line 3)"
  refute_output --partial "animated.gif"
  run find lib/images -name '*.gif'
  assert_output ""
  parseManifest work/m.txt 2> /dev/null
  assert_equal "${SIL_STOPSIL+set}" ""
}

@test "STOPSIL=off does not stop the manifest" {
  printf 'plasma.png\nSTOPSIL=off\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  refute_output --partial "rest of manifest skipped"
  assert_output --partial "[3] animated.gif"
}

@test "LIBRARY in a manifest is used, created if needed, then restored" {
  printf 'LIBRARY=%s\nplasma.png\n' "$TEST_SANDBOX/other" > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "Library: $TEST_SANDBOX/other (line 1)"
  run grep -cv '^#' other/images/fingerprints.txt
  assert_output 1
  run grep -cv '^#' lib/images/fingerprints.txt
  assert_output 0
  parseManifest work/m.txt 2> /dev/null
  assert_equal "$SIL_LIBRARY" "$TEST_SANDBOX/lib"
}

@test "a relative LIBRARY is relative to the manifest's folder" {
  printf 'LIBRARY=../rel\nplasma.png\n' > work/m.txt
  cd /
  parseManifest "$TEST_SANDBOX/work/m.txt" 2> /dev/null
  assert_dir_exists "$TEST_SANDBOX/rel/images"
}

@test "the manifest's library settings apply, below the manifest's own" {
  initLibrary "$TEST_SANDBOX/other" 2> /dev/null
  printf 'THRESHOLD=70\nSHRINKTRIGGER=3\n' > other/sil.conf
  printf 'SHRINKTRIGGER=4\nLIBRARY=%s\nplasma.png\n' "$TEST_SANDBOX/other" > work/m.txt
  ## Check settings while the manifest runs, from within processURI
  # shellcheck disable=SC2317  # Called by parseManifest
  processURI() { echo "seen $SIL_THRESHOLD $SIL_SHRINKTRIGGER" >&2; }
  run parseManifest work/m.txt
  assert_output --partial "seen 70 4"
}

@test "manifest settings are echoed with the value they replace, except TAG" {
  printf 'SHRINK=200k\nSHRINKVID=LOW\nTHRESHOLD=90\nTAG=First\n' > work/m.txt
  processURI() { :; }
  SIL_SHRINK=3072
  run parseManifest work/m.txt
  assert_output --partial "SHRINK = 204800 (200.0 KB), was 3072 (3.0 KB) (line 1)"
  assert_output --partial "SHRINKVID = LOW, was OFF (line 2)"
  assert_output --partial "THRESHOLD = 90, unchanged (line 3)"
  refute_output --partial "TAG ="
}

@test "LIBRARY after the first URI is ignored" {
  printf 'plasma.png\nLIBRARY=%s\nanimated.gif\n' "$TEST_SANDBOX/other" > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "LIBRARY must come before the first URI"
  assert_dir_not_exists other
}

@test "a manifest with no library at all is skipped" {
  unset SIL_LIBRARY
  printf 'plasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "No library for this manifest"
}

@test "an unknown parameter is reported, not treated as a file" {
  printf 'TAGG=Oops\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "Unrecognized parameter 'TAGG'"
  assert_output --partial "[ADDED]"
}

@test "a failed URI fails the manifest, but later URIs still run" {
  printf 'missing.png\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "[NOFILE]"
  assert_output --partial "[ADDED]"
}

# --- logs (REQ-08) ---------------------------------------------------

@test "the error log lists failures with reasons, as a manifest" {
  printf 'TAG=Before\nmissing-a.png\nplasma.png\nTAG=After\nmissing-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run grep -v '^#' work/m.txt.err
  assert_line --index 0 "LIBRARY=$(realpath lib)"
  assert_line --index 1 "FLATTEN=off"
  assert_line "TAG=Before"
  assert_line "TAG=After"
  assert_line "missing-a.png"
  assert_line "missing-b.png"
  refute_line "plasma.png"
  run grep -c '^THRESHOLD=' work/m.txt.err
  assert_output 1
  run grep -B1 '^missing-a.png$' work/m.txt.err
  assert_line --index 0 "# NOFILE: Local file does not exist"
}

@test "the error log groups failures by reason, with the first TAG on its own" {
  printf 'TAG=First\nmissing-a.png\nbad|.invalid\nmissing-b.png\n' > work/m.txt
  printf 'http://127.0.0.1:1/a.jpg\nTAG=Second\nmissing-c.png\n' >> work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run sed -n '/^[A-Z]/,$p' work/m.txt.err
  assert_line --index 0 "LIBRARY=$(realpath lib)"
  assert_line --index 1 "FLATTEN=off"
  run grep -A2 '^TOR=' work/m.txt.err
  assert_output "TOR=off

TAG=First"
  run grep -c '^# NOFILE' work/m.txt.err
  assert_output 1
  run sed -n '/^# NOFILE/,/^$/p' work/m.txt.err
  assert_output "# NOFILE: Local file does not exist
missing-a.png
bad|.invalid
missing-b.png
TAG=Second
missing-c.png"
  run sed -n '/^# UNREACHABLE/,/^$/p' work/m.txt.err
  assert_output "# UNREACHABLE: Could not connect to the website
TAG=First
http://127.0.0.1:1/a.jpg"
}

@test "failures from before the first TAG stay before it in the error log" {
  printf 'missing-a.png\nhttp://127.0.0.1:1/a.jpg\nTAG=Late\nmissing-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run grep -v '^#' work/m.txt.err
  refute_line --index 0 --partial "TAG="
  run grep -c '^# NOFILE' work/m.txt.err
  assert_output 2
  run sed -n '/^http/,$p' work/m.txt.err
  assert_output "http://127.0.0.1:1/a.jpg

# NOFILE: Local file does not exist
TAG=Late
missing-b.png"
}

@test "an error log from a manifest that set LIBRARY retries into it" {
  printf 'LIBRARY=../lib\nlate.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  cp work/plasma.png work/late.png
  mv work/m.txt.err work/retry.txt
  unset SIL_LIBRARY
  run parseManifest work/retry.txt
  assert_success
  assert_output --partial "[ADDED]"
}

@test "a regrouped error log retries each URI with its own TAG" {
  printf 'TAG=One\nlate-a.png\nhttp://127.0.0.1:1/a.jpg\nTAG=Two\nlate-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  cp work/plasma.png work/late-a.png
  convert -size 64x64 -seed 3 plasma:fractal work/late-b.png
  grep -v 127.0.0.1 work/m.txt.err > work/retry.txt
  parseManifest work/retry.txt 2> /dev/null
  run find lib/tags/One lib/tags/Two -type l
  assert_equal "${#lines[@]}" 2
  assert_line --partial "tags/One/"
  assert_line --partial "tags/Two/"
}

@test "error log comments are at most 80 characters, during and after a run" {
  ## During: comments hold the detail of the failure, which can be any length
  logStart work/m.txt
  _silLastOutcome=NOFILE
  _silLastHash=""
  _silLastDetail="$(printf 'x%.0s' {1..200})"
  logOutcome missing.png
  run grep '^# NOFILE' work/m.txt.err
  assert_equal "${#output}" 80
  ## After: comments hold each reason's meaning
  local tag comment
  for tag in "${!_silOutcomeMeaning[@]}"; do
    isSuccessTag "$tag" && continue
    comment="# $tag: ${_silOutcomeMeaning[$tag]}"
    (( ${#comment} <= 80 ))
  done
}

@test "the error log is written as failures happen, in case the run is interrupted" {
  ## The run never finishing, so the log is not regrouped
  # shellcheck disable=SC2317 # stand-in, called by parseManifest
  logFinish() { :; }
  printf 'TAG=Partial\nmissing.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run cat work/m.txt.err
  assert_line "TAG=Partial"
  assert_line "# NOFILE: File not found"
  assert_line "missing.png"
}

@test "the error log clears TAG, so a retry leaves later URIs untagged" {
  printf 'TAG=First\nlate-a.png\nTAG=\nlate-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run sed -n '/^# NOFILE/,$p' work/m.txt.err
  assert_output "# NOFILE: Local file does not exist
late-a.png
TAG=
late-b.png"
  cp work/plasma.png work/late-a.png
  convert -size 64x64 -seed 3 plasma:fractal work/late-b.png
  mv work/m.txt.err work/retry.txt
  parseManifest work/retry.txt 2> /dev/null
  run find lib/tags/First -type l
  assert_equal "${#lines[@]}" 1
  run find lib/tags/Untagged -type l
  assert_equal "${#lines[@]}" 1
}

@test "the error log clears UNTAG, so a retry adds later URIs" {
  printf 'UNTAG=Foo\nmissing.png\nUNTAG=\nlate.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  assert_file_contains work/m.txt.err '^UNTAG=$'
  cp work/plasma.png work/late.png
  mv work/m.txt.err work/retry.txt
  run parseManifest work/retry.txt
  assert_output --partial "[NOTSTORED]"
  assert_output --partial "[ADDED]"
}

@test "a clear is written only where a failure needs it, across reason groups" {
  printf 'TAG=First\nmissing-a.png\nTAG=\nhttp://127.0.0.1:1/a.jpg\nmissing-b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run sed -n '/^# NOFILE/,$p' work/m.txt.err
  assert_output "# NOFILE: Local file does not exist
missing-a.png
TAG=
missing-b.png

# UNREACHABLE: Could not connect to the website
http://127.0.0.1:1/a.jpg"
}

@test "a renamed error log retries the failures, with the same settings" {
  printf 'SHRINK=20kb\nTAG=Retry\nlate.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  cp work/plasma.png work/late.png
  mv work/m.txt.err work/retry.txt
  SIL_TAG=Ignored
  run parseManifest work/retry.txt
  assert_success
  assert_output --partial "[SHRINK]"
  run find lib/tags/Retry -type l
  assert_output --regexp '\.jpg$'
}

@test "the report lists outcomes, with legends only for tags that occur" {
  printf 'plasma.png\nplasma.png\nmissing.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  run cat work/m.txt.md
  assert_line --index 0 "# Load report for m.txt"
  assert_line --partial "- **ADDED** - "
  assert_line --partial "- **DUPE** - "
  refute_line --partial "**SHRINK**"
  assert_line --regexp '^\| ADDED \| [0-9a-f]{12} \| plasma.png \|$'
  assert_line "# Failed image download"
  assert_line --partial "- **NOFILE** - "
  refute_line --partial "**NOTFOUND**"
  assert_line "| NOFILE | missing.png |"
}

@test "with no failures, the report has no failure section" {
  printf 'plasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  run grep -c "Failed image download" work/m.txt.md
  assert_output 0
  run grep -v '^#' work/m.txt.err
  assert_output ""
  run tail -n 1 work/m.txt.err
  assert_output "# No failures"
}

@test "logs are overwritten on each run" {
  printf 'missing.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  printf 'plasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  run grep -c 'missing.png' work/m.txt.err work/m.txt.md
  assert_output "work/m.txt.err:0
work/m.txt.md:0"
}

@test "| in a URI is escaped in the report" {
  printf 'a|b.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null || true
  assert_file_contains work/m.txt.md 'a\\|b.png'
}

@test "a shrink that fails its check is SHRINKFAIL, logged for retry" {
  convert -size 320x240 -seed 9 plasma:fractal other.png
  ## Stand-in convert whose JPEG encoding produces a different picture
  convert() {
    if [[ "$*" == *jpeg:extent* ]]; then
      command convert "$TEST_SANDBOX/other.png" -quality 50 "${@: -1}"
    else
      command convert "$@"
    fi
  }
  printf 'SHRINK=50kb\nplasma.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "[SHRINKFAIL]"
  run grep -cv '^#' lib/images/fingerprints.txt
  assert_output 0
  run grep -A1 '^# SHRINKFAIL' work/m.txt.err
  assert_line --index 1 "plasma.png"
  assert_file_contains work/m.txt.err '^SHRINK=51200b$'
  assert_file_contains work/m.txt.md 'SHRINKFAIL'
}

@test "LINK runs at its line in a manifest, and isn't logged for retry" {
  cat > work/m.txt <<'EOF2'
LINK=Politics -> Meme/Politics
TAG=Politics
plasma.png
REMOVE
missing.png
EOF2
  run parseManifest work/m.txt
  assert_failure
  assert_link_exists lib/tags/Politics
  run find lib/tags/Meme/Politics -type l
  assert_output --regexp '\.png$'
  run cat work/m.txt.err
  refute_output --partial "LINK"
  assert_output --partial "REMOVE=on"
  assert_output --partial "# NOTSTORED"
}

@test "REMAP runs at its line in a manifest, and isn't logged for retry" {
  cp "$PROJECT_ROOT/test/data/images/transparent.png" work/
  cat > work/m.txt <<'EOF2'
TAG=Dog
plasma.png
REMAP=Dog -> Animal/Canine
TAG=Dog
transparent.png
REMOVE
missing.png
EOF2
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "Moved 1 file from Dog to Animal/Canine"
  assert_not_exists lib/tags/Dog
  run find lib/tags/Animal/Canine -type l
  assert_equal "${#lines[@]}" 2
  assert_file_contains lib/RemappedTags.txt '^Dog -> Animal/Canine$'
  run cat work/m.txt.err
  refute_output --partial "REMAP"
}

# --- what a manifest may hold (REQ-06) ---------------------------------

@test "a manifest can't name another manifest: it is a file like any other" {
  printf 'TAG=Inner\nplasma.png\n' > work/inner.txt
  printf 'inner.txt\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "[NOTIMAGE] Not an image (text/plain)"
  assert_output --partial "[ADDED]"
  run find lib/images -name '*.png'
  assert_output ""
  assert_not_exists lib/tags/Inner
  assert_not_exists work/inner.txt.err
}

@test "a manifest with Windows line endings works" {
  printf 'TAG=Crlf\r\nplasma.png\r\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "[ADDED]"
  run find lib/tags/Crlf -type l
  assert_output --regexp '\.png$'
}

@test "an empty manifest succeeds, with logs saying nothing happened" {
  : > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_file_contains work/m.txt.md "No images were added"
  assert_file_contains work/m.txt.err "No failures"
}

@test "a manifest can hold hash URIs, and files named like parameters" {
  local hash
  hash="$(fileHash work/plasma.png)"
  cp work/animated.gif "work/NAME=x"
  processURI work/plasma.png 2> /dev/null
  printf 'TAG=ByHash\n%s\nTAG=\nNAME=x\n' "$hash" > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "[FOUND]"
  assert_output --partial "[ADDED]"
  assert_link_exists "lib/tags/ByHash/$hash.png"
}

@test "a URL holding # is not cut short" {
  printf 'http://127.0.0.1:1/a.jpg#part\n' > work/m.txt
  run parseManifest work/m.txt
  assert_output --partial "[1] http://127.0.0.1:1/a.jpg#part"
  assert_file_contains work/m.txt.err '^http://127.0.0.1:1/a.jpg#part$'
}

@test "REMOVE=off and UNTAG= in a manifest end those operations" {
  processURI work/plasma.png 2> /dev/null
  printf 'REMOVE\nplasma.png\nREMOVE=off\nplasma.png\nUNTAG=Foo\nplasma.png\nUNTAG=\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_output --partial "[REMOVED]"
  assert_output --partial "[ADDED]"
  assert_output --partial "[FOUND]"
  run grep -c '^| ADDED ' work/m.txt.md
  assert_output 2
}

@test "LINK and REMAP before any library are reported and ignored" {
  unset SIL_LIBRARY
  printf 'LINK=A -> B\nREMAP=C -> D\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure
  assert_output --partial "LINK needs a library"
  assert_output --partial "REMAP needs a library"
}

@test "manifests and their images may be in folders with spaces" {
  mkdir "my work"
  cp work/plasma.png "my work/my pic.png"
  printf 'TAG=Spaced\nmy pic.png\n' > "my work/my list.txt"
  run parseManifest "my work/my list.txt"
  assert_success
  assert_output --partial "[ADDED]"
  assert_file_exists "my work/my list.txt.md"
}

# --- logs: other cases (REQ-08) ----------------------------------------

@test "every outcome is documented, within the length limit" {
  local tags
  tags="$(awk -F'|' '/^## Outcomes/,/^## Reporting/ {
      gsub(/ /, "", $2); if ($2 ~ /^[A-Z]+$/ && $2 !~ /^(Status|Reason)$/) print $2
    }' "$PROJECT_ROOT/docs/requirements.md" | sort)"
  assert_equal "$tags" "$(printf '%s\n' "${!_silOutcomeMeaning[@]}" | sort)"
  local tag
  for tag in $tags; do
    (( ${#tag} <= 12 ))
  done
}

@test "an upgrade is listed in the report with its new hash" {
  convert work/plasma.png -resize 200% work/big.png
  printf 'plasma.png\nKEEPLARGER\nbig.png\n' > work/m.txt
  run parseManifest work/m.txt
  assert_success
  assert_file_contains work/m.txt.md "^| UPGRADED | $(fileHash work/big.png | cut -c1-12) | big.png |$"
  assert_file_contains work/m.txt.md '^- \*\*UPGRADED\*\* - '
}

@test "if the manifest's folder can't be written, SIL warns and runs without logs" {
  (( EUID != 0 )) || skip "root can write to any folder"
  printf 'plasma.png\n' > work/m.txt
  chmod a-w work
  run parseManifest work/m.txt
  chmod u+w work
  assert_success
  assert_output --partial "Can't write logs beside the manifest"
  refute_output --partial "Permission denied"
  assert_output --partial "[ADDED]"
  assert_not_exists work/m.txt.err
  assert_not_exists work/m.txt.md
}

# --- halting part way (REQ-08) -----------------------------------------

@test "declining a LINK halts, with the results so far in the logs" {
  # shellcheck disable=SC2317 # stand-in answer, called by linkTag
  askYesNo() { return 1; }
  printf 'TAG=Old\nplasma.png\nmissing.png\nLINK=Old -> New/Old\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure 1
  assert_output --partial "No changes made: LINK Old -> New/Old"
  assert_output --partial "Report: work/m.txt.md"
  assert_output --partial "Failures, ready to retry: work/m.txt.err"
  refute_output --partial "animated.gif"
  [[ ! -L lib/tags/Old ]]

  run cat work/m.txt.md
  assert_line --regexp '^\| ADDED \| [0-9a-f]{12} \| plasma.png \|$'
  assert_line "| NOFILE | missing.png |"
  assert_line "**Stopped early; the rest of the manifest did not run:** No changes made: LINK Old -> New/Old"

  run cat work/m.txt.err
  assert_line "# NOFILE: Local file does not exist"
  assert_line "missing.png"
  assert_line "# Stopped early; the rest of the manifest did not run"
  assert_line "# Stopped: No changes made: LINK Old -> New/Old"
}

@test "a halt with no failures still says the manifest did not finish" {
  # shellcheck disable=SC2317 # stand-in answer, called by linkTag
  askYesNo() { return 1; }
  printf 'TAG=Old\nplasma.png\nLINK=Old -> New/Old\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure 1
  run cat work/m.txt.err
  assert_line "# No failures"
  assert_line "# Stopped early; the rest of the manifest did not run"
}

@test "a bad value halts a manifest, with the results so far in the logs" {
  printf 'plasma.png\nSHRINK=lots\nanimated.gif\n' > work/m.txt
  run parseManifest work/m.txt
  assert_failure 1
  assert_output --partial "Invalid size for SHRINK"
  assert_file_contains work/m.txt.md '^| ADDED | '
  assert_file_contains work/m.txt.md "Stopped early"
}

@test "a finished manifest leaves no halt hook behind" {
  printf 'plasma.png\n' > work/m.txt
  parseManifest work/m.txt 2> /dev/null
  assert_equal "$_silHaltHook" ""
  run grep -c "Stopped early" work/m.txt.md work/m.txt.err
  assert_output "work/m.txt.md:0
work/m.txt.err:0"
}
