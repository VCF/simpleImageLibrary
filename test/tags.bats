#!/usr/bin/env bats
## Tests for src/tags.sh

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "params"
  srcLib "tags"
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  storeImage "$PROJECT_ROOT/test/data/images/plasma.png" hash
}

teardown() {
  teardown_sandbox
}

@test "parseTags splits on commas and nests on / or :" {
  run parseTags " Humor , Animal:Mammal/ Dog ,,Meme/ "
  assert_success
  assert_output "Humor
Animal/Mammal/Dog
Meme"
}

@test "parseTags refuses . and .. levels" {
  run parseTags "ok,../../etc,a/./b"
  assert_failure
  assert_line --index 0 "ok"
  assert_output --partial "Tag '../../etc' ignored: '..' has no characters allowed"
  assert_output --partial "Tag 'a/./b' ignored"
}

@test "parseTags keeps letters, digits, space, _ and -, renaming others" {
  run parseTags "Fun!, Café Crème/Ñandú, snake_case-x, v1.5 , Ā漢x"
  assert_success
  assert_line "Fun"
  assert_line "Café Crème/Ñandú"
  assert_line "snake_case-x"
  assert_line "v15"
  assert_line "x"
  assert_output --partial "[!] Tag 'Fun!' renamed to 'Fun'"
  assert_output --partial "[!] Tag 'v1.5' renamed to 'v15'"
  refute_output --partial "renamed to 'Café"
  refute_output --partial "renamed to 'snake"
}

@test "accented tags match whatever their case, in any locale" {
  export LC_ALL=C
  tagImage "$hash" "Café"
  tagImage "$hash" "CAFÉ/Crème"
  assert_link_exists "lib/tags/Café/$hash.png"
  assert_link_exists "lib/tags/Café/Crème/$hash.png"
  run find lib/tags -mindepth 1 -maxdepth 1 -type d
  assert_output "lib/tags/Café"
}

@test "tagImage links by relative path, named after the image" {
  tagImage "$hash" Animal/Dog
  local link="lib/tags/Animal/Dog/$hash.png"
  assert_link_exists "$link"
  run readlink "$link"
  assert_output "../../../images/${hash:0:2}/${hash:2:2}/$hash.png"
  assert_file_exists "$link"
}

@test "tag folders are reused whatever their case" {
  mkdir -p lib/tags/Animal/Dog
  tagImage "$hash" animal/DOG
  assert_link_exists "lib/tags/Animal/Dog/$hash.png"
  run find lib/tags -mindepth 1 -type d
  assert_output "lib/tags/Animal
lib/tags/Animal/Dog"
}

@test "tagging through an alias folder links correctly" {
  ## As LINK will make: tags/Politics -> Meme/Politics
  mkdir -p lib/tags/Meme/Politics
  ln -s Meme/Politics lib/tags/Politics
  tagImage "$hash" Politics
  assert_link_exists "lib/tags/Meme/Politics/$hash.png"
  assert_file_exists "lib/tags/Meme/Politics/$hash.png"
}

@test "applyTags applies every tag in SIL_TAG, and repeats are harmless" {
  SIL_TAG="Humor, Meme/Classic"
  run applyTags "$hash"
  assert_success
  assert_output --partial "Tagged: Humor, Meme/Classic"
  applyTags "$hash" 2> /dev/null
  SIL_TAG="Humor, Fresh"
  run applyTags "$hash"
  assert_output --partial "Tagged: Humor (existed), Fresh"
  assert_link_exists "lib/tags/Humor/$hash.png"
  assert_link_exists "lib/tags/Meme/Classic/$hash.png"
}

@test "tagImage fails for an image not in the library" {
  run tagImage 0000000000000000000000000000000000000000 Humor
  assert_failure
}

# --- date tags (TAG-02) ----------------------------------------------

## Store a fresh image and date-tag it on a given day; sets $hash
storeOn() {
  convert -size 60x40 -seed "$2" plasma:fractal "img$2.png"
  storeImage "img$2.png" hash
  _silToday="$1" dateTagImage "$hash" 2> /dev/null
}

@test "dateTagImage links into tags/Date/YYYY/YYYY-MM-DD" {
  _silToday=2026-10-31 dateTagImage "$hash"
  assert_link_exists "lib/tags/Date/2026/2026-10-31/$hash.png"
  assert_file_exists "lib/tags/Date/2026/2026-10-31/$hash.png"
}

@test "new days link back and forth, across a year boundary" {
  storeOn 2025-12-30 1
  storeOn 2026-01-02 2
  local d=lib/tags/Date
  run readlink "$d/2026/2026-01-02/previous-2025-12-30"
  assert_output "../../2025/2025-12-30"
  run readlink "$d/2025/2025-12-30/next-2026-01-02"
  assert_output "../../2026/2026-01-02"
  assert_dir_exists "$d/2025/2025-12-30/next-2026-01-02/"
  run find "$d/2025/2025-12-30" -name 'previous-*'
  assert_output ""
}

@test "a second image on the same day adds no day links" {
  storeOn 2026-10-30 1
  storeOn 2026-10-31 2
  storeOn 2026-10-31 3
  run find lib/tags/Date -type l -name 'next-*'
  assert_equal "${#lines[@]}" 1
  run find lib/tags/Date/2026/2026-10-31 -type l ! -name 'previous-*'
  assert_equal "${#lines[@]}" 2
}

@test "a day added out of order is inserted between its neighbours" {
  storeOn 2026-10-01 1
  storeOn 2026-10-31 2
  storeOn 2026-10-15 3
  local d=lib/tags/Date/2026
  assert_link_exists "$d/2026-10-01/next-2026-10-15"
  assert_link_exists "$d/2026-10-15/previous-2026-10-01"
  assert_link_exists "$d/2026-10-15/next-2026-10-31"
  assert_link_exists "$d/2026-10-31/previous-2026-10-15"
  assert_not_exists "$d/2026-10-01/next-2026-10-31"
  dayLinksCorrect
}

@test "relinkDays repairs links after a merge of two clones' days" {
  storeOn 2026-10-30 1
  storeOn 2026-11-02 2
  ## The other clone added 11-01 after 10-30; git keeps both next links
  mkdir -p lib/tags/Date/2026/2026-11-01
  ln -s ../2026-11-01 lib/tags/Date/2026/2026-10-30/next-2026-11-01
  ln -s ../2026-10-30 lib/tags/Date/2026/2026-11-01/previous-2026-10-30
  run dayLinksCorrect
  assert_failure
  relinkDays
  dayLinksCorrect
  assert_link_exists lib/tags/Date/2026/2026-11-01/next-2026-11-02
  assert_not_exists lib/tags/Date/2026/2026-10-30/next-2026-11-02
}

@test "Date is reserved for automatic tags" {
  SIL_TAG="date/2020, Fine"
  run applyTags "$hash"
  assert_failure
  assert_output --partial "'Date' is reserved"
  assert_output --partial "Tagged: Fine"
  assert_not_exists lib/tags/date
}

# --- Untagged (TAG-03) -----------------------------------------------

@test "Untagged is reserved: TAG=Untagged is ignored with a hint" {
  SIL_TAG="Dog, untagged/Sub"
  run applyTags "$hash"
  assert_failure
  assert_output --partial "Tagged: Dog"
  assert_output --partial "'Untagged' is a reserved tag - if you wish to remove all tags from an image, use 'UNTAG=*'"
  assert_not_exists lib/tags/untagged
}

@test "a tag removes Untagged; a tag that existed does too" {
  markUntagged "$hash"
  assert_link_exists "lib/tags/Untagged/$hash.png"
  SIL_TAG=Dog
  applyTags "$hash" 2> /dev/null
  assert_not_exists lib/tags/Untagged
  assert_link_exists "lib/tags/Dog/$hash.png"
  markUntagged "$hash"
  applyTags "$hash" 2> /dev/null
  assert_not_exists lib/tags/Untagged
}

@test "ignored tags leave Untagged in place" {
  markUntagged "$hash"
  SIL_TAG="Untagged, Date/2020, !!"
  run applyTags "$hash"
  assert_failure
  refute_output --partial "Tagged:"
  assert_link_exists "lib/tags/Untagged/$hash.png"
}

@test "UNTAG of the last tag gives Untagged; UNTAG=Untagged is ignored" {
  tagImage "$hash" Animal/Dog
  tagImage "$hash" Cat
  SIL_UNTAG=Cat
  applyUntags "$hash" 2> /dev/null
  assert_not_exists lib/tags/Untagged
  SIL_UNTAG="animal/dog, Untagged"
  run applyUntags "$hash"
  assert_failure
  assert_output --partial "Untagged: animal/dog"
  assert_output --partial "'Untagged' is added and removed automatically - ignored"
  assert_link_exists "lib/tags/Untagged/$hash.png"
  assert_not_exists lib/tags/Animal
}

@test "UNTAG=* removes every tag but the date tag, giving Untagged" {
  dateTagImage "$hash" 2> /dev/null
  tagImage "$hash" Animal/Dog
  tagImage "$hash" Animal
  tagImage "$hash" Meme
  mkdir -p lib/tags/Keep
  ln -s Keep lib/tags/Alias
  tagImage "$hash" Alias
  SIL_UNTAG=" * "
  run applyUntags "$hash"
  assert_success
  assert_output --partial "Untagged: Animal, Animal/Dog, Keep, Meme"
  assert_not_exists lib/tags/Animal
  assert_not_exists lib/tags/Meme
  assert_not_exists "lib/tags/Keep/$hash.png"
  assert_link_exists lib/tags/Alias
  assert_link_exists "lib/tags/Untagged/$hash.png"
  run find lib/tags/Date -type l -name "$hash.png"
  assert_output --partial "$hash.png"
  run applyUntags "$hash"
  assert_output --partial "Had no tags to remove"
  assert_link_exists "lib/tags/Untagged/$hash.png"
}

# --- UNTAG -----------------------------------------------------------

@test "untagImage removes the link and prunes emptied folders" {
  tagImage "$hash" Animal/Dog
  tagImage "$hash" Animal/Cat
  untagImage "$hash" animal/dog
  assert_not_exists lib/tags/Animal/Dog
  assert_link_exists "lib/tags/Animal/Cat/$hash.png"
  untagImage "$hash" Animal/Cat
  assert_not_exists lib/tags/Animal
  assert_file_exists lib/tags/.gitkeep
}

@test "untagImage leaves tags below the one removed" {
  tagImage "$hash" Animal
  tagImage "$hash" Animal/Dog
  untagImage "$hash" Animal
  assert_not_exists "lib/tags/Animal/$hash.png"
  assert_link_exists "lib/tags/Animal/Dog/$hash.png"
}

@test "untagImage fails, creating nothing, for a tag the image lacks" {
  run untagImage "$hash" No/Such
  assert_failure
  assert_not_exists lib/tags/No
}

@test "applyUntags reports removed and absent tags; Date is reserved" {
  tagImage "$hash" Fine
  dateTagImage "$hash" 2> /dev/null
  SIL_UNTAG="Fine, Missing, Date"
  run applyUntags "$hash"
  assert_failure
  assert_output --partial "Untagged: Fine"
  assert_output --partial "Did not have tag: Missing"
  assert_output --partial "'Date' is reserved"
  run find lib/tags/Date -type l -name "$hash.png"
  assert_output --partial "$hash.png"
}

@test "pruneTagFolder keeps a folder that a LINK points to" {
  mkdir -p lib/tags/Meme/Politics
  ln -s Meme/Politics lib/tags/Politics
  pruneTagFolder "$(realpath lib/tags/Meme/Politics)"
  assert_dir_exists lib/tags/Meme/Politics
}

@test "pruneTagFolder removes an emptied day and relinks its neighbours" {
  local day
  for day in 2026-01-01 2026-01-02 2026-01-03; do
    _silToday="$day"
    dateTagImage "$hash" 2> /dev/null
  done
  rm "lib/tags/Date/2026/2026-01-02/$hash.png"
  pruneTagFolder "$(realpath lib/tags/Date/2026/2026-01-02)"
  assert_not_exists lib/tags/Date/2026/2026-01-02
  assert_link_exists lib/tags/Date/2026/2026-01-01/next-2026-01-03
  dayLinksCorrect
}

# --- LINK ------------------------------------------------------------

@test "LINK makes a new source tag a link to the target" {
  linkTag "Politics -> Meme/Politics"
  assert_link_exists lib/tags/Politics
  run readlink lib/tags/Politics
  assert_output Meme/Politics
  tagImage "$hash" politics
  assert_link_exists "lib/tags/Meme/Politics/$hash.png"
}

@test "LINK works for nested sources and is repeatable" {
  linkTag "Fun:Politics -> Meme/Politics"
  run readlink lib/tags/Fun/Politics
  assert_output ../Meme/Politics
  run linkTag "fun/politics -> meme/politics"
  assert_success
  assert_output --partial "Already linked"
}

@test "LINK replaces an empty source folder" {
  mkdir -p lib/tags/Politics/Empty
  linkTag "Politics -> Meme/Politics"
  assert_link_exists lib/tags/Politics
}

@test "LINK moves a source's images to the target when the user agrees" {
  tagImage "$hash" Politics
  tagImage "$hash" Politics/Local
  # shellcheck disable=SC2317 # stand-in answer, called by linkTag
  askYesNo() { return 0; }
  linkTag "Politics -> Meme/Politics"
  assert_link_exists lib/tags/Politics
  assert_file_exists "lib/tags/Meme/Politics/$hash.png"
  assert_file_exists "lib/tags/Meme/Politics/Local/$hash.png"
  assert_file_exists "lib/tags/Politics/Local/$hash.png"
}

@test "LINK changes nothing when the user declines" {
  tagImage "$hash" Politics
  # shellcheck disable=SC2317 # stand-in answer, called by linkTag
  askYesNo() { return 1; }
  run linkTag "Politics -> Meme/Politics"
  assert_failure
  assert_output --partial "No changes made"
  assert_file_exists "lib/tags/Politics/$hash.png"
  [[ ! -L lib/tags/Politics ]]
}

@test "LINK repoints a source that is already a link" {
  linkTag "Politics -> Meme/Politics"
  run linkTag "Politics -> News/Politics"
  assert_success
  assert_output --partial "Unlinked Politics"
  run readlink lib/tags/Politics
  assert_output News/Politics
}

@test "LINK refuses bad values, loops and reserved tags" {
  local bad reason
  while IFS='|' read -r bad reason; do
    run linkTag "$bad"
    assert_failure
    assert_output --partial "$reason"
  done <<'EOF'
Politics|needs a source and target
A,B -> C|exactly one source and one target
-> C|exactly one source and one target
A -> Date/2020|'Date' is a reserved tag
Date -> A|'Date' is a reserved tag
untagged -> A|'Untagged' is a reserved tag
A -> Untagged|'Untagged' is a reserved tag
Meme/Politics -> Meme|source can't be inside its target
Meme -> Meme/Politics|target can't be inside its source
EOF
  [[ ! -L lib/tags/Date && ! -L lib/tags/Meme && ! -e lib/tags/A ]]
}

@test "askYesNo halts when there is no terminal to ask at" {
  run setsid -w bash -c "myDir='$PROJECT_ROOT'; source '$PROJECT_ROOT/src/utils.sh'
    srcLib tags; askYesNo 'Go on?'" < /dev/null
  assert_failure
  assert_output --partial "no terminal to ask at"
}

## Run a LINK through sil at a real terminal, typing the given answers
linkAtTerminal() {
  command -v script > /dev/null || skip "script (bsdutils) is not installed"
  printf '%b' "$1" | script -qec \
    "'$PROJECT_ROOT/sil' LIBRARY=lib 'LINK=Politics -> Meme/Politics'" /dev/null
}

@test "at a terminal, answering N to LINK changes nothing" {
  tagImage "$hash" Politics
  run linkAtTerminal 'n\n'
  assert_failure
  assert_output --partial "[Y/N]"
  assert_output --partial "No changes made"
  [[ ! -L lib/tags/Politics ]]
  assert_file_exists "lib/tags/Politics/$hash.png"
}

@test "at a terminal, LINK asks again until answered Y, then moves the images" {
  tagImage "$hash" Politics
  run linkAtTerminal 'maybe\nY\n'
  assert_success
  assert_link_exists lib/tags/Politics
  assert_file_exists "lib/tags/Meme/Politics/$hash.png"
}

# --- REMAP -----------------------------------------------------------

## Read the remap file again, as the next run of sil would
nextRun() {
  _silRemapsLibrary=""
  syncRemaps
}

@test "REMAP quietly applies the target instead of the source" {
  remapAdd "Dog -> Animal/Canine" 2> /dev/null
  SIL_TAG="dog"
  run applyTags "$hash"
  assert_success
  assert_output --partial "Tagged: Animal/Canine"
  refute_output --partial "[!]"
  refute_output --partial "dog"
  assert_not_exists lib/tags/Dog
  assert_not_exists lib/tags/dog
  assert_link_exists "lib/tags/Animal/Canine/$hash.png"
}

@test "remapTag follows chains and leading levels, longest source first" {
  _silRemaps=([dog]="Animal/Canine" [dog/puppy]="Young/Pup" [animal/canine/wolf]="Wild")
  run remapTag "Dog/Beagle"
  assert_output "Animal/Canine/Beagle"
  run remapTag "DOG/puppy/Small"
  assert_output "Young/Pup/Small"
  run remapTag "Dog/Wolf"
  assert_output "Wild"
  ## A source only matches from the top of the path
  run remapTag "Pets/Dog"
  assert_output "Pets/Dog"
}

@test "remapTag returns the tag given if remaps loop, even as they grow" {
  _silRemaps=([a]="B/x" [b]="A")
  run remapTag "A"
  assert_failure
  assert_output "A"
}

@test "UNTAG follows remaps too" {
  remapAdd "Dog -> Animal/Canine" 2> /dev/null
  tagImage "$hash" Animal/Canine
  SIL_UNTAG="Dog"
  run applyUntags "$hash"
  assert_success
  assert_output --partial "Untagged: Animal/Canine"
  assert_not_exists lib/tags/Animal/Canine
}

@test "a tag and its remapped form in one TAG are applied once" {
  remapAdd "Dog -> Animal/Canine" 2> /dev/null
  SIL_TAG="Dog,animal/canine"
  run applyTags "$hash"
  assert_success
  refute_output --partial "(existed)"
}

@test "REMAP moves a source's files to the target, reporting the count" {
  tagImage "$hash" Dog
  tagImage "$hash" Dog/Puppy
  run remapAdd "Dog -> Animal/Canine"
  assert_success
  assert_output --partial "Moved 2 files from Dog to Animal/Canine"
  assert_not_exists lib/tags/Dog
  assert_link_exists "lib/tags/Animal/Canine/$hash.png"
  assert_link_exists "lib/tags/Animal/Canine/Puppy/$hash.png"
  [[ -f "lib/tags/Animal/Canine/Puppy/$hash.png" ]]
}

@test "REMAP says nothing of moving when a source has no files, and prunes its parents" {
  mkdir -p lib/tags/Pets/Dog/Sub
  run remapAdd "Pets/Dog -> Animal"
  assert_success
  refute_output --partial "Moved"
  assert_not_exists lib/tags/Pets
  assert_not_exists lib/tags/Animal
}

@test "REMAP merges into a target that already has the image" {
  tagImage "$hash" Dog
  tagImage "$hash" Canine
  run remapAdd "Dog -> Canine"
  assert_success
  assert_output --partial "Moved 1 file from Dog to Canine"
  assert_not_exists lib/tags/Dog
  assert_link_exists "lib/tags/Canine/$hash.png"
}

@test "REMAP of a LINK alias removes only the link" {
  tagImage "$hash" Pets/Dog
  ln -s Pets/Dog lib/tags/Dog
  run remapAdd "Dog -> Animal/Canine"
  assert_success
  assert_output --partial "Removed link Dog"
  [[ ! -e lib/tags/Dog && ! -L lib/tags/Dog ]]
  assert_link_exists "lib/tags/Pets/Dog/$hash.png"
  assert_not_exists lib/tags/Animal
}

@test "REMAP points a LINK to the source at the target" {
  tagImage "$hash" Dog
  ln -s Dog lib/tags/Hound
  run remapAdd "Dog -> Animal/Canine"
  assert_success
  assert_output --partial "Link Hound now points to Animal/Canine"
  assert_not_exists lib/tags/Dog
  assert_equal "$(readlink lib/tags/Hound)" "Animal/Canine"
  [[ -f "lib/tags/Hound/$hash.png" ]]
}

@test "REMAP moves a LINK inside the source so that it still works" {
  tagImage "$hash" Other
  mkdir -p lib/tags/Dog
  ln -s ../Other lib/tags/Dog/Alias
  run remapAdd "Dog -> Animal/Canine"
  assert_success
  [[ -f "lib/tags/Animal/Canine/Alias/$hash.png" ]]
}

@test "REMAP refuses bad values, loops and reserved tags" {
  local bad reason
  while IFS='|' read -r bad reason; do
    run remapAdd "$bad"
    assert_failure
    assert_output --partial "$reason"
  done <<'EOF'
Dog|needs a source and target
A,B -> C|exactly one source and one target
-> C|exactly one source and one target
A -> B -> C|needs a source and target
A -> Date/2020|'Date' is a reserved tag
Date -> A|'Date' is a reserved tag
untagged -> A|'Untagged' is a reserved tag
A -> Untagged|'Untagged' is a reserved tag
Dog -> Dog|target can't be its source or inside it
Dog -> dog/Sub|target can't be its source or inside it
EOF
  assert_not_exists lib/RemappedTags.txt
}

@test "REMAP refuses a loop through other remaps, keeping the file as it was" {
  remapAdd "A -> B" 2> /dev/null
  remapAdd "B -> C" 2> /dev/null
  run remapAdd "C -> A"
  assert_failure
  assert_output --partial "would loop"
  run grep -c '^C ->' lib/RemappedTags.txt
  assert_output 0
  run remapTag A
  assert_output C
}

@test "REMAP to a remapped target moves files to the final target" {
  remapAdd "B -> C" 2> /dev/null
  tagImage "$hash" A
  run remapAdd "A -> B"
  assert_success
  assert_output --partial "Moved 1 file from A to C"
  assert_not_exists lib/tags/B
  assert_link_exists "lib/tags/C/$hash.png"
}

@test "REMAP keeps the file's other lines, and replaces a source's line" {
  cat > lib/RemappedTags.txt <<'EOF'
# My vocabulary
Kitty -> Feline

not a remap
dog -> Old
EOF
  run remapAdd "Dog -> Canine"
  assert_success
  assert_output --partial "Remapped: Dog -> Canine, was Old"
  run cat lib/RemappedTags.txt
  assert_output "# My vocabulary
Kitty -> Feline

not a remap
Dog -> Canine"
  run remapAdd "DOG -> canine"
  assert_success
  assert_output --partial "Already remapped"
}

@test "the first REMAP makes a file explaining itself" {
  remapAdd "Dog -> Canine" 2> /dev/null
  assert_file_contains lib/RemappedTags.txt "^# One remap per line"
  assert_file_contains lib/RemappedTags.txt "^Dog -> Canine$"
}

@test "a remap file edited by hand is acted on at the next run" {
  tagImage "$hash" Dog
  syncRemaps
  ## CRLF line endings and no final newline, as an editor might leave
  printf '# Notes\r\n\r\n  dog:puppy -> Young \r\nDog->Animal/Canine' > lib/RemappedTags.txt
  tagImage "$hash" Dog/Puppy
  run nextRun
  assert_success
  assert_output --partial "Moved 1 file from dog/puppy to Young"
  assert_output --partial "Moved 1 file from Dog to Animal/Canine"
  refute_output --partial "[!]"
  assert_not_exists lib/tags/Dog
  assert_link_exists "lib/tags/Animal/Canine/$hash.png"
  assert_link_exists "lib/tags/Young/$hash.png"
}

@test "a line removed by hand stops the remap at the next run" {
  remapAdd "Dog -> Canine" 2> /dev/null
  : > lib/RemappedTags.txt
  nextRun
  run remapTag Dog
  assert_output Dog
}

@test "a missing or empty remap file is fine, and a deleted one stops remaps" {
  run nextRun
  assert_success
  assert_output ""
  : > lib/RemappedTags.txt
  run nextRun
  assert_success
  assert_output ""
  remapAdd "Dog -> Canine" 2> /dev/null
  rm lib/RemappedTags.txt
  nextRun
  run remapTag Dog
  assert_output Dog
}

@test "problem lines in a remap file are warned about, ignored and kept" {
  cat > lib/RemappedTags.txt <<'EOF'
no arrow here
A,B -> C
Date -> D
E -> E/Sub
Good -> Fine
EOF
  cp lib/RemappedTags.txt expected
  run nextRun
  assert_success
  assert_output --partial "RemappedTags.txt line 1"
  assert_output --partial "RemappedTags.txt line 2"
  assert_output --partial "RemappedTags.txt line 3"
  assert_output --partial "RemappedTags.txt line 4"
  refute_output --partial "line 5"
  assert_files_equal lib/RemappedTags.txt expected
  nextRun 2> /dev/null
  assert_equal "${#_silRemaps[@]}" 1
  assert_equal "${_silRemaps[good]}" Fine
}

@test "a remap file with a loop or repeated source is handled" {
  tagImage "$hash" Solo
  cat > lib/RemappedTags.txt <<'EOF'
A -> B
B -> A
Twice -> First
twice -> Second
Solo -> Kept
EOF
  run nextRun
  assert_success
  assert_output --partial "REMAP loops, ignored: A -> B"
  assert_output --partial "'twice' is listed more than once; using 'Second'"
  assert_output --partial "Moved 1 file from Solo to Kept"
  nextRun 2> /dev/null
  run remapTag Twice
  assert_output Second
  ## Dropping one remap of the loop leaves the other, which no longer loops
  run remapTag B
  assert_success
  assert_output A
}

@test "a source that is a physical parent of its target stays, with a warning" {
  tagImage "$hash" Dog
  ln -s Dog lib/tags/Hound
  printf 'Dog -> Hound/Sub\n' > lib/RemappedTags.txt
  run nextRun
  assert_failure
  assert_output --partial "left in place"
  assert_link_exists "lib/tags/Dog/$hash.png"
  assert_not_exists lib/tags/Dog/Sub
}

@test "remaps are read for each library used" {
  remapAdd "Dog -> Canine" 2> /dev/null
  SIL_LIBRARY="$TEST_SANDBOX/lib2"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  syncRemaps
  run remapTag Dog
  assert_output Dog
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  syncRemaps
  run remapTag Dog
  assert_output Canine
}

@test "LINK follows a remapped target and refuses a remapped source" {
  remapAdd "Dog -> Animal/Canine" 2> /dev/null
  run linkTag "Dog -> Other"
  assert_failure
  assert_output --partial "is remapped to 'Animal/Canine'"
  assert_not_exists lib/tags/Dog
  run linkTag "Hound -> Dog"
  assert_success
  assert_output --partial "Linked: Hound -> Animal/Canine"
  assert_equal "$(readlink lib/tags/Hound)" "Animal/Canine"
}

# --- REMOVE ----------------------------------------------------------

@test "removeImage removes the file, its tags, index and sources lines" {
  tagImage "$hash" Animal/Dog
  dateTagImage "$hash" 2> /dev/null
  sourceAdd "$hash" https://example.com/a.png
  storeImage "$PROJECT_ROOT/test/data/images/animated.gif" other
  sourceAdd "$other" https://example.com/b.gif
  removeImage "$hash"
  run findStoredImage "$hash"
  assert_failure
  run find lib/tags -name "$hash.*"
  assert_output ""
  assert_not_exists lib/tags/Animal
  assert_not_exists lib/tags/Date
  run grep -c "$hash" lib/images/fingerprints.txt lib/images/sources.txt
  assert_output --partial "fingerprints.txt:0"
  assert_output --partial "sources.txt:0"
  grep -q "$other" lib/images/fingerprints.txt
  grep -q "$other" lib/images/sources.txt
  assert_not_exists "lib/images/${hash:0:2}/${hash:2:2}"
}

@test "removeImage keeps other images in shared tag folders" {
  storeImage "$PROJECT_ROOT/test/data/images/animated.gif" other
  tagImage "$hash" Shared
  tagImage "$other" Shared
  removeImage "$hash"
  assert_link_exists "lib/tags/Shared/$other.gif"
}
