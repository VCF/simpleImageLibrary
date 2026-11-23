#!/usr/bin/env bats
## Tests for src/maintain.sh (CHECK and REBUILD)

# Each bats test runs in its own subshell, which is intended, and SIL_*
# parameters are read by the sourced code
# shellcheck disable=SC2030,SC2031,SC2034

load test_helper

setup() {
  setup_sandbox
  myDir="$PROJECT_ROOT"
  source "$PROJECT_ROOT/src/utils.sh"
  srcLib "maintain"
  srcLib "library"
  SIL_LIBRARY="$TEST_SANDBOX/lib"
  initLibrary "$SIL_LIBRARY" 2> /dev/null
  DATA="$PROJECT_ROOT/test/data/images"
  storeImage "$DATA/plasma.png" plasma
  storeImage "$DATA/animated.gif" anim
  markUntagged "$plasma"
  markUntagged "$anim"
  PLASMA="lib/images/${plasma:0:2}/$plasma.png"
}

teardown() {
  teardown_sandbox
}

@test "a healthy library passes CHECK" {
  run libraryCheck
  assert_success
  assert_output --partial "No problems found in 2 stored images"
}

@test "CHECK finds a damaged file" {
  printf 'x' >> "$PLASMA"
  run libraryCheck
  assert_failure
  assert_output --partial "does not match its name"
}

@test "CHECK finds a file in the wrong folder" {
  mkdir -p lib/images/zz
  mv "$PLASMA" lib/images/zz/
  run libraryCheck
  assert_failure
  assert_output --partial "Stored in the wrong folder"
  assert_output --partial "sil REBUILD moves it to images/${plasma:0:2}/"
}

@test "CHECK finds unexpected files" {
  touch lib/images/holiday.jpg
  run libraryCheck
  assert_failure
  assert_output --partial "Unexpected file in images: images/holiday.jpg"
}

@test "CHECK finds index entries without images, and images not indexed" {
  rm "$PLASMA"
  convert -size 100x100 -seed 5 plasma:fractal new.png
  local h
  h="$(sha1sum new.png | cut -c1-40)"
  mkdir -p "lib/images/${h:0:2}"
  cp new.png "lib/images/${h:0:2}/$h.png"
  run libraryCheck
  assert_failure
  assert_output --partial "lists an image that isn't stored: $plasma"
  assert_output --partial "Not in fingerprint index: images/${h:0:2}/$h.png"
  assert_output --partial "sil REBUILD"
}

@test "CHECK finds malformed and repeated index lines" {
  echo "garbage" >> lib/images/fingerprints.txt
  grep "^$anim " lib/images/fingerprints.txt > repeat.txt
  cat repeat.txt >> lib/images/fingerprints.txt
  run libraryCheck
  assert_failure
  assert_output --partial "Malformed fingerprint index line"
  assert_output --partial "listed twice in fingerprint index: $anim"
}

@test "CHECK finds broken tag links" {
  mkdir -p lib/tags/Animal
  ln -s ../../images/no/ne/missing.jpg lib/tags/Animal/missing.jpg
  run libraryCheck
  assert_failure
  assert_output --partial "Broken tag link: tags/Animal/missing.jpg"
}

@test "REBUILD regenerates a damaged index, matching the original" {
  cp lib/images/fingerprints.txt original.txt
  echo "garbage" > lib/images/fingerprints.txt
  indexRebuild
  run diff <(grep -v '^#' original.txt | sort) \
    <(grep -v '^#' lib/images/fingerprints.txt | sort)
  assert_success
  run libraryCheck
  assert_success
}

@test "REBUILD skips unexpected files and leaves no temp files" {
  touch lib/images/holiday.jpg
  libraryRebuild
  run grep -c -v '^#' lib/images/fingerprints.txt
  assert_output 2
  assert_file_exists lib/images/holiday.jpg
  run find lib/.tmp lib/images -name 'sil.*'
  assert_output ""
}

@test "CHECK reports missing library files; REBUILD restores them" {
  rm lib/.gitignore lib/tags/.gitkeep
  run libraryCheck
  assert_failure
  assert_output --partial "Missing library file: .gitignore"
  assert_output --partial "Missing library file: tags/.gitkeep"
  libraryRebuild
  assert_files_equal lib/.gitignore "$PROJECT_ROOT/templates/gitignore"
  assert_file_exists lib/tags/.gitkeep
}

## Tag an image by hand, as tagging will: tags/<tag>/<file> -> image
tagByHand() {
  local image="$1" tag="$2"
  mkdir -p "lib/tags/$tag"
  ln -s "$(relativePath "lib/tags/$tag" "$image")" "lib/tags/$tag/$(basename "$image")"
}

@test "REBUILD renames an edited image and keeps its tags" {
  tagByHand "$PLASMA" Animal/Dog
  tagByHand "$PLASMA" Meme
  ## Edit in place: still a PNG, but new content and so a new hash
  convert "$PLASMA" -rotate 180 "$PLASMA"
  local new
  new="$(sha1sum "$PLASMA" | cut -c1-40)"
  libraryRebuild
  assert_file_not_exists "$PLASMA"
  assert_file_exists "lib/images/${new:0:2}/$new.png"
  assert_file_exists "lib/tags/Animal/Dog/$new.png"
  assert_file_exists "lib/tags/Meme/$new.png"
  run readlink "lib/tags/Animal/Dog/$new.png"
  assert_output "../../../images/${new:0:2}/$new.png"
  assert_not_exists "lib/tags/Animal/Dog/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD moves a misplaced image and keeps its tags" {
  mkdir -p lib/images/zz
  mv "$PLASMA" lib/images/zz/
  tagByHand "lib/images/zz/$plasma.png" Bird
  libraryRebuild
  assert_file_exists "$PLASMA"
  assert_dir_not_exists lib/images/zz
  run readlink "lib/tags/Bird/$plasma.png"
  assert_output "../../images/${plasma:0:2}/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD fixes a wrong suffix and keeps tags" {
  local wrong="${PLASMA%.png}.jpg"
  mv "$PLASMA" "$wrong"
  tagByHand "$wrong" Bird
  libraryRebuild
  assert_file_exists "$PLASMA"
  assert_file_exists "lib/tags/Bird/$plasma.png"
  run libraryCheck
  assert_success
}

@test "REBUILD merges a second copy, keeping both copies' tags" {
  ## A copy edited to match another stored image exactly
  local animFile="lib/images/${anim:0:2}/$anim.gif"
  tagByHand "$PLASMA" Original
  tagByHand "$animFile" Copy
  sourceAdd "$plasma" https://example.com/first.png
  sourceAdd "$anim" https://example.com/second.gif
  cp "$PLASMA" "$animFile"
  libraryRebuild
  assert_file_not_exists "$animFile"
  assert_file_exists "lib/tags/Original/$plasma.png"
  assert_file_exists "lib/tags/Copy/$plasma.png"
  run grep -v '^#' lib/images/sources.txt
  assert_output "$plasma https://example.com/first.png
$plasma https://example.com/second.gif"
  run libraryCheck
  assert_success
}

@test "REBUILD leaves unreadable images alone and reports them" {
  local h="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "lib/images/01"
  cp "$DATA/not-an-image.jpg" "lib/images/01/$h.jpg"
  run libraryRebuild
  assert_failure
  assert_output --partial "Not a readable, supported image, left alone"
  assert_file_exists "lib/images/01/$h.jpg"
}

@test "sil REBUILD CHECK runs both, rebuild first" {
  rm lib/images/fingerprints.txt
  cd lib
  run "$PROJECT_ROOT/sil" CHECK REBUILD
  assert_success
  assert_output --partial "Added images/fingerprints.txt"
  assert_output --partial "Fingerprint index rebuilt: 2 images"
  assert_output --partial "No problems found"
}

@test "sil CHECK exits 1 on problems" {
  touch lib/images/stray.txt
  run "$PROJECT_ROOT/sil" LIBRARY=lib CHECK
  assert_failure 1
}

@test "REBUILD keeps sources when it renames an image" {
  sourceAdd "$plasma" https://example.com/p.png
  sourceAdd "$plasma" https://example.com/p2.png
  convert "$PLASMA" -rotate 90 "$PLASMA"
  local new
  new="$(sha1sum "$PLASMA" | cut -c1-40)"
  libraryRebuild
  run grep -v '^#' lib/images/sources.txt
  assert_output "$new https://example.com/p.png
$new https://example.com/p2.png"
  run libraryCheck
  assert_success
}

@test "CHECK reports sources for images that aren't stored" {
  sourceAdd 0123456789abcdef0123456789abcdef01234567 https://example.com/gone.png
  run libraryCheck
  assert_failure
  assert_output --partial "Source recorded for an image that isn't stored"
  assert_output --partial "Fix: if the image was removed on purpose"
}

@test "CHECK reports malformed sources lines, with a fix" {
  echo "garbage" >> lib/images/sources.txt
  run libraryCheck
  assert_failure
  assert_output --regexp "Malformed sources line [0-9]+: garbage"
  assert_output --partial "Fix: correct or remove this line in images/sources.txt"
}

@test "CHECK reports an image stored twice; REBUILD keeps one, with its tags" {
  mkdir -p lib/images/zz
  cp "$PLASMA" lib/images/zz/
  tagByHand "lib/images/zz/$plasma.png" Copy
  run libraryCheck
  assert_failure
  assert_output --partial "Image stored twice"
  assert_output --partial "Fix: sil REBUILD keeps one"
  run libraryRebuild
  assert_output --partial "Removed second copy"
  assert_file_exists "lib/tags/Copy/$plasma.png"
  run libraryCheck
  assert_success
}

## Print every path in the library with its type, target, size, time and
## content hash, so that any change at all shows up as a difference
librarySnapshot() {
  find lib -printf '%p %y %l %s %T@\n' | LC_ALL=C sort
  find lib -type f -exec sha1sum {} + | LC_ALL=C sort
}

@test "CHECK changes nothing, however broken the library" {
  ## One of each problem that REBUILD would act on
  tagByHand "$PLASMA" Meme
  rm lib/.gitignore lib/tags/Untagged/"$anim".gif
  mkdir -p lib/images/zz lib/tags/Date/2026/2026-10-30 lib/tags/Date/2026/2026-10-31
  mv "$PLASMA" lib/images/zz/
  touch lib/images/holiday.jpg
  ln -s ../nowhere.png lib/tags/Meme/broken.png
  echo "garbage" | tee -a lib/images/fingerprints.txt >> lib/images/sources.txt
  librarySnapshot > before.txt
  run libraryCheck
  assert_failure
  librarySnapshot > after.txt
  assert_files_equal before.txt after.txt
}

## Write one small file of a stored format, by its suffix
makeStoredFormat() {
  local suffix="$1" file="$2" still="$DATA/plasma.png"
  case "$suffix" in
    mp4|mov) ffmpeg -v error -f lavfi -i testsrc=size=64x48:rate=5:duration=1 \
        -c:v libx264 -pix_fmt yuv420p "$file" ;;
    webm) ffmpeg -v error -f lavfi -i testsrc=size=64x48:rate=5:duration=1 \
        -c:v libvpx-vp9 "$file" ;;
    avif) ffmpeg -v error -i "$still" -c:v libaom-av1 -still-picture 1 \
        -pix_fmt yuv420p "$file" ;;
    *) convert "$still" -resize 64x48! "$file" ;;
  esac
}

@test "every stored format passes CHECK and stays in the index after REBUILD" {
  local suffix hash n=2
  for suffix in $(printf '%s\n' "${_silImageSuffix[@]}" | sort -u); do
    [[ "$suffix" == png || "$suffix" == gif ]] && continue
    makeStoredFormat "$suffix" "sample.$suffix"
    storeImage "sample.$suffix" hash
    markUntagged "$hash"
    assert_file_exists "$(storedImagePath "$hash" "$suffix")"
    n=$(( n + 1 ))
  done
  run libraryCheck
  assert_success
  assert_output --partial "No problems found in $n stored images"
  libraryRebuild 2> /dev/null
  run grep -cv '^#' lib/images/fingerprints.txt
  assert_output "$n"
  run libraryCheck
  assert_success
}

@test "CHECK reports, and REBUILD fixes, out of date day links" {
  mkdir -p lib/tags/Date/2026/2026-10-30 lib/tags/Date/2026/2026-10-31
  run libraryCheck
  assert_failure
  assert_output --partial "Date tag next/previous links are out of date"
  libraryRebuild
  run libraryCheck
  assert_success
}

@test "CHECK reports, and REBUILD fixes, wrong Untagged tags" {
  ## anim: no tags at all (eg stored before TAG-03); plasma: Untagged and Meme
  rm "lib/tags/Untagged/$anim.gif"
  tagByHand "$PLASMA" Meme
  run libraryCheck
  assert_failure
  assert_output --partial "1 images have no tags, but aren't tagged Untagged"
  assert_output --partial "1 images are tagged Untagged, but have other tags too"
  run libraryRebuild
  assert_output --partial "Tagged Untagged: 1 images with no tags"
  assert_output --partial "Removed Untagged from 1 images with other tags"
  assert_link_exists "lib/tags/Untagged/$anim.gif"
  assert_not_exists "lib/tags/Untagged/$plasma.png"
  run libraryCheck
  assert_success
}

# --- SHARED (REQ-13) ----------------------------------------------------

@test "REBUILD makes everything match SHARED, keeping execute bits and links" {
  mkdir -p lib/.git/hooks
  printf '#!/bin/sh\n' > lib/.git/hooks/pre-commit
  chmod 755 lib/.git/hooks/pre-commit
  touch outside
  chmod 640 outside
  ln -s "$TEST_SANDBOX/outside" lib/tags/link
  chmod 644 lib/sil.conf

  SIL_SHARED=0
  libraryRebuild 2> /dev/null
  run stat -c %a lib lib/images lib/sil.conf lib/images/fingerprints.txt "$(findStoredImage "$plasma")" lib/.git/hooks/pre-commit outside
  assert_output "700
700
600
600
600
700
640"

  SIL_SHARED=1
  libraryRebuild 2> /dev/null
  run stat -c %a lib lib/images lib/sil.conf lib/images/fingerprints.txt "$(findStoredImage "$plasma")" lib/.git/hooks/pre-commit outside
  assert_output "755
755
644
644
644
755
640"
}

@test "REBUILD reports permissions it can't change" {
  chmod() { return 1; }
  run repairPermissions
  assert_failure
  assert_output --partial "Could not set permissions"
}

# --- Image layout (REQ-05) ----------------------------------------------

## Tags as in everyday use, settled by a REBUILD: nested tags, several per
## image, a LINK alias, Untagged, and two date tag days with their links
richLibrary() {
  tagImage "$plasma" Animal/Dog
  tagImage "$plasma" Meme
  linkTag "Pets -> Animal" 2> /dev/null
  dateTagImage "$plasma"
  tagByHand "$(findStoredImage "$anim")" Date/2026/2026-10-30
  libraryRebuild 2> /dev/null
  run libraryCheck
  assert_success
}

## Every path with its type and link target, and each file's content: any
## change shows, except to modification times
layoutSnapshot() {
  find lib -path lib/.tmp -prune -o -printf '%p %y %l\n' | LC_ALL=C sort
  find lib -path lib/.tmp -prune -o -type f -exec sha1sum {} + | LC_ALL=C sort
}

@test "a new library records the current image layout" {
  run libraryLayout lib
  assert_output 2
  run grep -v '^#' lib/images/layout.txt
  assert_output "layout 2"
}

@test "a library with no image folders is current, and gets a layout file" {
  mkdir -p bare/images bare/tags
  run libraryLayout bare
  assert_output 2
  assert_file_exists bare/images/layout.txt
}

@test "a library from before the layout file is layout 1; an unreadable one is 0" {
  toLayout1 lib
  run libraryLayout lib
  assert_output 1
  assert_file_not_exists lib/images/layout.txt
  echo "garbage" > lib/images/layout.txt
  run libraryLayout lib
  assert_output 0
}

@test "CHECK reports an older layout once, and changes nothing" {
  richLibrary
  toLayout1 lib
  layoutSnapshot > before.txt
  run libraryCheck
  assert_failure
  assert_output --partial "2 images are stored in the older images/xx/yy/ layout"
  assert_output --partial "Fix: sil REBUILD moves them to images/xx/"
  refute_output --partial "Stored in the wrong folder"
  refute_output --partial "Broken tag link"
  layoutSnapshot > after.txt
  assert_files_equal before.txt after.txt
}

@test "REBUILD moves an older layout, keeping every image, tag and link" {
  richLibrary
  imageMap lib > images.before
  linkMap lib > links.before
  cp lib/images/fingerprints.txt lib/images/sources.txt .
  toLayout1 lib
  run libraryRebuild
  assert_success
  assert_output --partial "Moving 2 images from images/xx/yy/ to images/xx/"
  assert_output --partial "Library now uses image layout 2"
  run libraryLayout lib
  assert_output 2
  ## Nothing left in, or below, an images/xx/yy/ folder
  run find lib/images -mindepth 2 -type d
  assert_output ""
  imageMap lib > images.after
  assert_files_equal images.before images.after
  linkMap lib > links.after
  assert_files_equal links.before links.after
  run grep -c BROKEN links.after
  assert_output 0
  run find lib/tags -type l -lname '/*'
  assert_output ""
  assert_files_equal fingerprints.txt lib/images/fingerprints.txt
  assert_files_equal sources.txt lib/images/sources.txt
  run libraryCheck
  assert_success
  ## Links are relative, so the library still works when moved
  mv lib moved
  run find moved/tags -xtype l
  assert_output ""
}

@test "a second REBUILD after a move changes nothing" {
  richLibrary
  toLayout1 lib
  libraryRebuild 2> /dev/null
  layoutSnapshot > before.txt
  run libraryRebuild
  assert_success
  refute_output --partial "Moving"
  refute_output --partial "Relinked"
  layoutSnapshot > after.txt
  assert_files_equal before.txt after.txt
}

@test "REBUILD finishes a move that was interrupted" {
  richLibrary
  linkMap lib > links.before
  toLayout1 lib
  ## Interrupted after moving one image, before its links were changed
  mv "lib/images/${plasma:0:2}/${plasma:2:2}/$plasma.png" "lib/images/${plasma:0:2}/"
  run libraryCheck
  assert_failure
  assert_output --partial "Fix: sil REBUILD points it at its image"
  run libraryRebuild
  assert_success
  linkMap lib > links.after
  assert_files_equal links.before links.after
  run libraryLayout lib
  assert_output 2
  run libraryCheck
  assert_success
}

@test "REBUILD merges an identical copy left in the older layout, eg by git" {
  local old="lib/images/${plasma:0:2}/${plasma:2:2}"
  mkdir -p "$old"
  cp "$PLASMA" "$old/"
  tagByHand "$old/$plasma.png" Merged
  run libraryCheck
  assert_failure
  assert_output --partial "1 images are stored in the older images/xx/yy/ layout"
  run libraryRebuild
  assert_success
  assert_output --partial "removed 1 copies identical to one already moved"
  assert_dir_not_exists "$old"
  run readlink -e "lib/tags/Merged/$plasma.png"
  assert_output "$(realpath "$PLASMA")"
  run libraryCheck
  assert_success
}

@test "a different file in an image's place stops REBUILD, losing no tag" {
  richLibrary
  linkMap lib > links.before
  toLayout1 lib
  local legacy="lib/images/${plasma:0:2}/${plasma:2:2}/$plasma.png"
  cp "$DATA/animated.gif" "$PLASMA"
  run libraryRebuild
  assert_failure
  assert_output --partial "Not moved, as a different file is already in its place: ${legacy#lib/}"
  assert_output --partial "REBUILD stopped before repairing anything else"
  refute_output --partial "Library now uses image layout 2"
  run libraryLayout lib
  assert_output 1
  assert_file_exists "$legacy"
  linkMap lib > links.after
  assert_files_equal links.before links.after
  ## Once the user removes the wrong file, REBUILD finishes
  rm "$PLASMA"
  run libraryRebuild
  assert_success
  linkMap lib > links.after
  assert_files_equal links.before links.after
  run libraryCheck
  assert_success
}

@test "REBUILD moves an unreadable file by name, then reports it" {
  toLayout1 lib
  local h="0123456789abcdef0123456789abcdef01234567"
  mkdir -p lib/images/01/23
  cp "$DATA/not-an-image.jpg" "lib/images/01/23/$h.jpg"
  run libraryRebuild
  assert_failure
  assert_output --partial "Library now uses image layout 2"
  assert_output --partial "Not a readable, supported image, left alone: images/01/$h.jpg"
  assert_file_exists "lib/images/01/$h.jpg"
}

@test "REBUILD points a broken link at its image, renaming it for a new suffix" {
  mkdir -p lib/tags/Bird lib/tags/Cat
  ln -s "../../images/zz/$plasma.png" "lib/tags/Bird/$plasma.png"
  ln -s "../../images/${plasma:0:2}/$plasma.jpg" "lib/tags/Cat/$plasma.jpg"
  ln -s ../../images/no/missing.jpg lib/tags/Cat/missing.jpg
  run libraryRebuild
  assert_output --partial "Relinked 2 tag links to their images"
  run readlink "lib/tags/Bird/$plasma.png"
  assert_output "../../images/${plasma:0:2}/$plasma.png"
  assert_file_exists "lib/tags/Cat/$plasma.png"
  assert_not_exists "lib/tags/Cat/$plasma.jpg"
  ## A link to an image that isn't stored is left for the user
  assert_link_exists lib/tags/Cat/missing.jpg
  run libraryCheck
  assert_failure
  assert_output --partial "Broken tag link: tags/Cat/missing.jpg"
  assert_output --partial "Fix: remove the link"
}

@test "REBUILD rebuilds the web page of a library it moves" {
  srcLib "web"
  buildWeb 2> /dev/null
  toLayout1 lib
  run libraryRebuild
  assert_success
  assert_output --partial "BUILDWEB: building the library web page"
  run grep -c 'slice(2, 4)' lib/web/websil.js
  assert_output 0
  run grep -c "\"$plasma\"" lib/web/imageData.js
  assert_output 1
}
