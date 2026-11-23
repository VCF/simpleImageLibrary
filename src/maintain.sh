## Library maintenance: CHECK and REBUILD - see REQ-09

srcLib "index"
srcLib "tags"

#######################################
# List every file under the library's images folder, except the
# fingerprint index and sources file.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   One path per line to STDOUT, sorted
#######################################
function listImageFiles {
    find "$SIL_LIBRARY/images" -type f ! -path "$(indexFile)" \
        ! -path "$(sourcesFile)" ! -path "$(layoutFile "$SIL_LIBRARY")" | sort
}

#######################################
# List files named like stored images that are too deep in the images
# folder for the current layout: in an images/xx/yy/ folder of layout 1,
# or deeper.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   One path per line to STDOUT, sorted
#######################################
function listLegacyImageFiles {
    find "$SIL_LIBRARY/images" -mindepth 3 -type f -regextype posix-extended \
        -regex '.*/[0-9a-f]{40}\.[a-z0-9]+' | LC_ALL=C sort
}

#######################################
# List the names of the stored images, wherever they are in the images
# folder, each once.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   One file name per line to STDOUT, sorted (C locale)
#######################################
function listStoredNames {
    find "$SIL_LIBRARY/images" -mindepth 2 -type f -regextype posix-extended \
        -regex '.*/[0-9a-f]{40}\.[a-z0-9]+' -printf '%f\n' | LC_ALL=C sort -u
}

#######################################
# Count the tag links, date tag included, that reach a stored image.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   The count to STDOUT
#######################################
function countImageLinks {
    find "$SIL_LIBRARY/tags" -type l -xtype f -regextype posix-extended \
        -regex '.*/[0-9a-f]{40}\.[a-z0-9]+' -printf '.' | wc -c
}

#######################################
# Point broken tag links back at their images. A tag link is named after
# its image's file, so a link whose image has moved, but not changed, is
# found by its name: in the current place for that name, or else stored
# under the same hash with another suffix (the link is then renamed).
# Needs no record of what moved, so works after an interrupted REBUILD.
# Links whose image isn't stored are left for CHECK to report.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe
# Outputs:
#   How many links were fixed, to STDERR
#######################################
function relinkBrokenTags {
    local link dir name hash image fixed=0
    while IFS= read -r link; do
        name="${link##*/}"
        [[ "$name" =~ $_silStoredNameRe ]] || continue
        hash="${BASH_REMATCH[1]}"
        image="$SIL_LIBRARY/images/${hash:0:2}/$name"
        if [[ ! -f "$image" ]] && ! image="$(findStoredImage "$hash")"; then
            continue
        fi
        dir="${link%/*}"
        if [[ "${image##*/}" == "$name" ]]; then
            ## Replaced in one step (ln makes the new link, then renames it
            ## over the old), so an interruption can't lose the tag
            ln -sfn -- "$(relativePath "$dir" "$image")" "$link" || continue
        else
            if [[ ! -L "$dir/${image##*/}" ]]; then
                ln -s -- "$(relativePath "$dir" "$image")" "$dir/${image##*/}" || continue
            fi
            rm -f -- "$link"
        fi
        fixed=$(( fixed + 1 ))
        (( fixed % 100 )) || msgStatus "  Relinked $fixed tag links: ${link#"$SIL_LIBRARY"/}"
    done < <(find "$SIL_LIBRARY/tags" -xtype l | LC_ALL=C sort)
    (( fixed )) && msgInfo "  Relinked $fixed tag links to their images"
    return 0
}

#######################################
# Move stored images from an older layout (REQ-05) to the current one, and
# relink their tags. Files are moved by name, so even unreadable ones are
# moved; repairStoredImages then deals with their contents. If a file of
# the same name is already in place, an identical older copy is removed,
# and a different one is left where it is and reported.
#
# Safety: it can be interrupted and run again, as each file move is a
# rename, and relinkBrokenTags needs no record of earlier moves. Afterwards
# it confirms that every image name, and every tag link reaching an image,
# is still there. The layout file is only updated once no image is left
# in an older layout and those checks pass, so until then SIL won't use
# the library for anything but CHECK and REBUILD.
# Globals:
#   SIL_LIBRARY, _silImageLayout
# Outputs:
#   Progress, a summary and problems to STDERR
# Returns:
#   0 if the library is now in the current layout, 1 otherwise
#######################################
function migrateImageLayout {
    local f name want n=0 moved=0 dropped=0 failed=0 rv=0
    local namesBefore namesAfter missing linksBefore linksAfter
    local -a legacy
    mapfile -t legacy < <(listLegacyImageFiles)
    if (( ${#legacy[@]} == 0 )); then
        (( "$(libraryLayout "$SIL_LIBRARY")" == _silImageLayout )) && return 0
        if ! layoutWrite "$SIL_LIBRARY"; then
            msgWarn "[!] Could not write $(layoutFile "$SIL_LIBRARY")"
            return 1
        fi
        msgInfo "  Recorded image layout $_silImageLayout in images/layout.txt"
        return 0
    fi

    msgInfo "Moving ${#legacy[@]} images from images/xx/yy/ to images/xx/
    If this is interrupted, run sil REBUILD again to finish"
    if ! namesBefore="$(silMktemp)" || ! namesAfter="$(silMktemp)"; then
        msgError "[!] Could not write to the library's temp folder: $SIL_LIBRARY/.tmp"
    fi
    listStoredNames > "$namesBefore"
    linksBefore="$(countImageLinks)"

    for f in "${legacy[@]}"; do
        n=$(( n + 1 ))
        (( n % 100 )) || msgStatus "  Moving $n of ${#legacy[@]}: ${f#"$SIL_LIBRARY"/}"
        name="${f##*/}"
        want="$SIL_LIBRARY/images/${name:0:2}/$name"
        if [[ -e "$want" || -L "$want" ]]; then
            if cmp -s -- "$f" "$want"; then
                rm -f -- "$f"
                dropped=$(( dropped + 1 ))
            else
                msgWarn "[!] Not moved, as a different file is already in its place: ${f#"$SIL_LIBRARY"/}
    Compare it with ${want#"$SIL_LIBRARY"/}, remove whichever is wrong, then run sil REBUILD again"
                failed=$(( failed + 1 ))
            fi
        elif { [[ -d "${want%/*}" ]] || mkdir -p -- "${want%/*}"; } && mv -- "$f" "$want"; then
            moved=$(( moved + 1 ))
        else
            msgWarn "[!] Could not move ${f#"$SIL_LIBRARY"/} to ${want#"$SIL_LIBRARY"/}"
            failed=$(( failed + 1 ))
        fi
    done
    find "$SIL_LIBRARY/images" -mindepth 2 -type d -empty -delete
    msgInfo "  Moved $moved images; removed $dropped copies identical to one already moved"
    relinkBrokenTags

    listStoredNames > "$namesAfter"
    missing="$(LC_ALL=C comm -23 "$namesBefore" "$namesAfter")"
    rm -f -- "$namesBefore" "$namesAfter"
    if [[ -n "$missing" ]]; then
        msgWarn "[!] These images were in the library before the move, but are not now:
$missing
    Restore them from a backup, then run sil REBUILD again"
        rv=1
    fi
    linksAfter="$(countImageLinks)"
    if (( linksAfter < linksBefore )); then
        msgWarn "[!] $linksBefore tag links reached an image before the move, but only $linksAfter do now
    'sil CHECK' lists broken tag links"
        rv=1
    fi
    if (( failed || rv )); then
        msgWarn "[!] The library stays in the older image layout until the problems above are fixed
    and sil REBUILD is run again"
        return 1
    fi
    if ! layoutWrite "$SIL_LIBRARY"; then
        msgWarn "[!] Could not write $(layoutFile "$SIL_LIBRARY")"
        return 1
    fi
    msgInfo "  All images moved, and $linksAfter tag links checked. Library now uses image layout $_silImageLayout"
}

## Moves made by repairStoredImages: old absolute path -> new absolute
## path. Read by retargetTagLinks
declare -gA _silMoved=()

#######################################
# Give every stored image its correct name and place (REQ-05): named by
# its current sha1sum, with the suffix of its current format, in its
# images/xx/ folder. Fixes images edited after storage, misplaced
# files, and wrong suffixes. If the correct name is already taken (the
# same image stored twice), the extra copy is removed. Files not named
# like stored images, or not readable as images, are left alone.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe; sets _silMoved
# Outputs:
#   Status lines, one line per change, and problems, to STDERR
# Returns:
#   0 on success, 1 if any file could not be repaired
#######################################
function repairStoredImages {
    local f name format hash want failed=0 n=0
    _silMoved=()
    while IFS= read -r f; do
        n=$(( n + 1 ))
        msgStatus "  Checking name $n: ${f#"$SIL_LIBRARY"/}"
        name="$(basename -- "$f")"
        [[ "$name" =~ $_silStoredNameRe ]] || continue
        if ! format="$(imageFormat "$f")"; then
            msgWarn "[!] Not a readable, supported image, left alone: ${f#"$SIL_LIBRARY"/}"
            failed=$(( failed + 1 ))
            continue
        fi
        hash="$(fileHash "$f")"
        want="$(storedImagePath "$hash" "${_silImageSuffix[$format]}")"
        [[ "$f" == "$want" ]] && continue

        if [[ -f "$want" ]]; then
            rm -f -- "$f"
            msgInfo "  Removed second copy: ${f#"$SIL_LIBRARY"/} (same as ${want#"$SIL_LIBRARY"/})"
        elif mkdir -p -- "$(dirname -- "$want")" && mv -- "$f" "$want"; then
            msgInfo "  Renamed: ${f#"$SIL_LIBRARY"/} -> ${want#"$SIL_LIBRARY"/}"
        else
            msgWarn "[!] Could not move ${f#"$SIL_LIBRARY"/} to ${want#"$SIL_LIBRARY"/}"
            failed=$(( failed + 1 ))
            continue
        fi
        _silMoved["$f"]="$want"
    done < <(listImageFiles)

    ## Folders emptied by moves
    find "$SIL_LIBRARY/images" -mindepth 1 -type d -empty -delete
    (( failed == 0 ))
}

#######################################
# Point tag links at images moved by repairStoredImages. Each link is
# replaced by one named after the image's new file name, with a new
# relative target. Links to images that weren't moved are untouched.
# Globals:
#   SIL_LIBRARY, _silMoved
# Outputs:
#   One line per link updated, to STDERR
#######################################
function retargetTagLinks {
    (( ${#_silMoved[@]} )) || return 0
    local link dir target new newLink
    while IFS= read -r link; do
        dir="$(dirname -- "$link")"
        target="$(realpath -m -- "$dir/$(readlink -- "$link")")"
        new="${_silMoved[$target]:-}"
        [[ -n "$new" ]] || continue
        newLink="$dir/$(basename -- "$new")"
        rm -f -- "$link"
        [[ -L "$newLink" ]] || ln -s -- "$(relativePath "$dir" "$new")" "$newLink"
        msgInfo "  Updated tag: ${link#"$SIL_LIBRARY"/} -> ${newLink#"$SIL_LIBRARY"/}"
    done < <(find "$SIL_LIBRARY/tags" -type l | sort)
}

#######################################
# Find stored images whose Untagged tag (TAG-03) is wrong: those with no
# user tags and no Untagged tag (eg stored before TAG-03), and those
# with both. One pass over the tags folder, for large libraries.
# Globals:
#   SIL_LIBRARY, _silDateTag, _silUntaggedTag, _silStoredNameRe
# Outputs:
#   One "add <hash>" or "drop <hash>" line per image to STDOUT
#######################################
function untaggedMismatches {
    local root name f
    local -A user=() untagged=()
    root="$(realpath -- "$SIL_LIBRARY/tags")"
    while IFS= read -r name; do
        user[$name]=1
    done < <(find "$root" \( -path "$root/$_silDateTag" -o -path "$root/$_silUntaggedTag" \) \
        -prune -o -type l -printf '%f\n')
    if [[ -d "$root/$_silUntaggedTag" ]]; then
        while IFS= read -r name; do
            untagged[$name]=1
        done < <(find "$root/$_silUntaggedTag" -mindepth 1 -maxdepth 1 -type l -printf '%f\n')
    fi
    while IFS= read -r f; do
        name="$(basename -- "$f")"
        [[ "$name" =~ $_silStoredNameRe ]] || continue
        if [[ -n "${user[$name]:-}" && -n "${untagged[$name]:-}" ]]; then
            printf 'drop %s\n' "${BASH_REMATCH[1]}"
        elif [[ -z "${user[$name]:-}" && -z "${untagged[$name]:-}" ]]; then
            printf 'add %s\n' "${BASH_REMATCH[1]}"
        fi
    done < <(listImageFiles)
}

#######################################
# Correct every stored image's Untagged tag (untaggedMismatches).
# Outputs:
#   How many images were changed, and problems, to STDERR
# Returns:
#   0 on success, 1 if any image could not be tagged
#######################################
function repairUntagged {
    local action hash added=0 dropped=0 rv=0
    while read -r action hash; do
        if [[ "$action" == add ]]; then
            if markUntagged "$hash"; then
                added=$(( added + 1 ))
            else
                rv=1
            fi
        else
            dropUntagged "$hash"
            dropped=$(( dropped + 1 ))
        fi
    done < <(untaggedMismatches)
    (( added )) && msgInfo "  Tagged $_silUntaggedTag: $added images with no tags"
    (( dropped )) && msgInfo "  Removed $_silUntaggedTag from $dropped images with other tags"
    (( rv )) && msgWarn "[!] Some images could not be tagged $_silUntaggedTag"
    return "$rv"
}

#######################################
# Regenerate the fingerprint index from the stored images. The new index
# is built in the library's temp folder and replaces the old one only
# once complete.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe
# Outputs:
#   Progress and problems to STDERR
# Returns:
#   0 on success, 1 if any stored image could not be fingerprinted;
#   halts (msgError) if the index can't be written
#######################################
function indexRebuild {
    local entries new f name hash fp hex
    local count=0 failed=0
    if ! entries="$(silMktemp)" || ! new="$(silMktemp)"; then
        msgError "[!] Could not write to the library's temp folder: $SIL_LIBRARY/.tmp"
    fi

    msgInfo "Rebuilding fingerprint index"
    while IFS= read -r f; do
        name="$(basename -- "$f")"
        ## Unexpected files are reported by CHECK, not indexed
        [[ "$name" =~ $_silStoredNameRe ]] || continue
        hash="${BASH_REMATCH[1]}"
        msgStatus "  Fingerprinting $(( count + failed + 1 )): ${f#"$SIL_LIBRARY"/}"
        if ! fp="$(imageFingerprint "$f")" || ! hex="$(fingerprintToHex "$fp")"; then
            msgWarn "[!] Could not fingerprint, left out of the index: ${f#"$SIL_LIBRARY"/}"
            failed=$(( failed + 1 ))
            continue
        fi
        printf '%s %s\n' "$hash" "$hex" >> "$entries"
        count=$(( count + 1 ))
    done < <(listImageFiles)

    indexWriteSorted "$new" < "$entries"
    rm -f -- "$entries"
    placeLibraryFile "$new" "$(indexFile)"
    msgInfo "Fingerprint index rebuilt: $count images"
    (( failed == 0 ))
}

#######################################
# Update the sources file for images moved by repairStoredImages, so
# each keeps its sources under its new hash.
# Globals:
#   _silMoved
# Returns:
#   0 on success, 1 if the sources file can't be written
#######################################
function retargetSources {
    (( ${#_silMoved[@]} )) || return 0
    local map old rv=0
    map="$(silMktemp)" || return 1
    for old in "${!_silMoved[@]}"; do
        printf '%s %s\n' "$(basename -- "${old%.*}")" \
            "$(basename -- "${_silMoved[$old]%.*}")" >> "$map"
    done
    sourcesRehash "$map" || rv=1
    rm -f -- "$map"
    return "$rv"
}

#######################################
# Give everything in the library the permissions SHARED calls for, including
# files made earlier or by git. Symbolic modes keep the owner's own access and
# any execute bits, as on git hooks. chmod -R doesn't follow the tag links.
# Globals:
#   SIL_LIBRARY, SIL_SHARED
# Outputs:
#   Progress and problems to STDERR
# Returns:
#   0 on success, 1 if anything could not be changed
#######################################
function repairPermissions {
    local mode="go-rwx" text="owner only"
    if flagIsSet SHARED; then
        mode="go+rX"
        text="everyone"
    fi
    msgInfo "Making library readable by $text"
    if ! chmod -R "$mode" -- "$SIL_LIBRARY"; then
        msgWarn "[!] Could not set permissions on everything in the library"
        return 1
    fi
}

#######################################
# REBUILD (REQ-09): restore missing library files, move images from an
# older layout (REQ-05; stopping there if that fails), relink broken tag
# links, repair stored image
# names and places while keeping their tags and sources, correct the
# Untagged tag (TAG-03), relink the date tag's days, regenerate the
# fingerprint index, then apply SHARED to the permissions of everything.
# A library web page is rebuilt if images were moved to a new layout, as
# it finds images by the layout.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   Progress and problems to STDERR
# Returns:
#   0 on success, 1 if anything could not be repaired; halts (msgError)
#   if needed tools are missing
#######################################
function libraryRebuild {
    requireTool convert imagemagick "inspect and fingerprint stored images"
    requireTool findimagedupes findimagedupes "fingerprint stored images"
    requireTool ffmpeg ffmpeg "fingerprint stored animations and videos"
    local rv=0 layout started
    started="$(clockMark)"
    msgInfo "Rebuilding library: $SIL_LIBRARY"
    libraryEnsureFiles "$SIL_LIBRARY"
    layout="$(libraryLayout "$SIL_LIBRARY")"
    ## Before repairStoredImages, whose record of moves is only for links
    ## that work when it starts. If the move is incomplete, stop: images
    ## have only been moved by name, so the user can see what to fix
    if ! migrateImageLayout; then
        msgWarn "[!] REBUILD stopped before repairing anything else"
        return 1
    fi
    relinkBrokenTags
    repairStoredImages || rv=1
    retargetTagLinks
    retargetSources || rv=1
    repairUntagged || rv=1
    relinkDays
    indexRebuild || rv=1
    repairPermissions || rv=1
    ## BUILDWEB, if given, builds it once REBUILD is done
    if (( layout != _silImageLayout )) && [[ -d "$SIL_LIBRARY/web" ]] && ! flagIsSet BUILDWEB \
        && layoutProblem "$SIL_LIBRARY" > /dev/null; then
        srcLib "web"
        buildWeb || rv=1
    fi
    msgInfo "REBUILD finished: $(elapsedText "$started")"
    return "$rv"
}

#######################################
# Check the library for problems (REQ-09), reporting each with a fix.
# Changes nothing.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe
# Outputs:
#   Problems and a summary to STDERR
# Returns:
#   0 if no problems were found, 1 otherwise
#######################################
function libraryCheck {
    local problems=0 indexProblems=0 n=0 oldLayout=0
    local -A stored=() indexed=()
    local f rel name hash dir expected actual fix
    local index line lineNum=0 action added=0 dropped=0

    msgInfo "Checking library: $SIL_LIBRARY"

    for f in sil.conf .gitignore .gitattributes tags/.gitkeep \
        images/fingerprints.txt images/sources.txt; do
        if [[ ! -e "$SIL_LIBRARY/$f" ]]; then
            msgWarn "[!] Missing library file: $f
    Fix: sil REBUILD adds it"
            problems=$(( problems + 1 ))
        fi
    done

    while IFS= read -r f; do
        rel="${f#"$SIL_LIBRARY"/}"
        n=$(( n + 1 ))
        msgStatus "  Checking $n: $rel"
        name="$(basename -- "$f")"
        if [[ ! "$name" =~ $_silStoredNameRe ]]; then
            msgWarn "[!] Unexpected file in images: $rel
    Fix: move it out of images; to add it to the library, use sil"
            problems=$(( problems + 1 ))
            continue
        fi
        hash="${BASH_REMATCH[1]}"
        expected="images/${hash:0:2}"
        dir="$(dirname -- "$rel")"
        if [[ "$dir" == images/*/* ]]; then
            ## An older layout: summed up below, rather than one per image
            oldLayout=$(( oldLayout + 1 ))
        elif [[ "$dir" != "$expected" ]]; then
            msgWarn "[!] Stored in the wrong folder: $rel
    Fix: sil REBUILD moves it to $expected/, keeping its tags"
            problems=$(( problems + 1 ))
        fi
        actual="$(fileHash "$f")"
        if [[ "$actual" != "$hash" ]]; then
            msgWarn "[!] File does not match its name, it may be damaged or edited: $rel
    Its sha1sum is $actual
    Fix: if the change was intended, sil REBUILD renames it, keeping its
    tags; otherwise restore it from a backup"
            problems=$(( problems + 1 ))
        fi
        if [[ -n "${stored[$hash]:-}" ]]; then
            msgWarn "[!] Image stored twice: ${stored[$hash]} and $rel
    Fix: sil REBUILD keeps one, moving tags to it"
            problems=$(( problems + 1 ))
        fi
        stored[$hash]="$rel"
    done < <(listImageFiles)

    if (( oldLayout )); then
        msgWarn "[!] $oldLayout images are stored in the older images/xx/yy/ layout (REQ-05)
    Fix: sil REBUILD moves them to images/xx/, keeping their tags. First back up
    the library, and update sil on every computer sharing it"
        problems=$(( problems + 1 ))
    elif (( "$(libraryLayout "$SIL_LIBRARY")" != _silImageLayout )); then
        msgWarn "[!] The image layout file is missing or out of date: images/layout.txt
    Fix: sil REBUILD"
        problems=$(( problems + 1 ))
    fi

    index="$(indexFile)"
    if [[ -f "$index" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineNum=$(( lineNum + 1 ))
            [[ "$line" == \#* ]] && continue
            if [[ ! "$line" =~ ^([0-9a-f]{40})\ [0-9a-f]{64}$ ]]; then
                msgWarn "[!] Malformed fingerprint index line $lineNum: $line"
                indexProblems=$(( indexProblems + 1 ))
                continue
            fi
            hash="${BASH_REMATCH[1]}"
            if [[ -n "${indexed[$hash]:-}" ]]; then
                msgWarn "[!] Image listed twice in fingerprint index: $hash"
                indexProblems=$(( indexProblems + 1 ))
            elif [[ -z "${stored[$hash]:-}" ]]; then
                msgWarn "[!] Fingerprint index lists an image that isn't stored: $hash"
                indexProblems=$(( indexProblems + 1 ))
            fi
            indexed[$hash]=1
        done < "$index"
    fi
    for hash in "${!stored[@]}"; do
        if [[ -z "${indexed[$hash]:-}" ]]; then
            msgWarn "[!] Not in fingerprint index: ${stored[$hash]}"
            indexProblems=$(( indexProblems + 1 ))
        fi
    done
    if (( indexProblems )); then
        msgWarn "    Fix for fingerprint index problems: sil REBUILD"
        problems=$(( problems + indexProblems ))
    fi

    lineNum=0
    if [[ -f "$(sourcesFile)" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineNum=$(( lineNum + 1 ))
            [[ "$line" == \#* ]] && continue
            if [[ ! "$line" =~ ^([0-9a-f]{40})\ .+$ ]]; then
                msgWarn "[!] Malformed sources line $lineNum: $line
    Fix: correct or remove this line in images/sources.txt"
                problems=$(( problems + 1 ))
            elif [[ -z "${stored[${BASH_REMATCH[1]}]:-}" ]]; then
                msgWarn "[!] Source recorded for an image that isn't stored: $line
    Fix: if the image was removed on purpose, remove this line from images/sources.txt"
                problems=$(( problems + 1 ))
            fi
        done < "$(sourcesFile)"
    fi

    while IFS= read -r f; do
        fix="remove the link"
        name="$(basename -- "$f")"
        if [[ "$name" =~ $_silStoredNameRe ]] && findStoredImage "${BASH_REMATCH[1]}" > /dev/null; then
            fix="sil REBUILD points it at its image"
        fi
        msgWarn "[!] Broken tag link: ${f#"$SIL_LIBRARY"/} -> $(readlink -- "$f")
    Fix: $fix"
        problems=$(( problems + 1 ))
    done < <(find "$SIL_LIBRARY/tags" -xtype l 2> /dev/null | sort)

    while read -r action hash; do
        if [[ "$action" == add ]]; then
            added=$(( added + 1 ))
        else
            dropped=$(( dropped + 1 ))
        fi
    done < <(untaggedMismatches)
    if (( added )); then
        msgWarn "[!] $added images have no tags, but aren't tagged $_silUntaggedTag
    Fix: sil REBUILD"
        problems=$(( problems + 1 ))
    fi
    if (( dropped )); then
        msgWarn "[!] $dropped images are tagged $_silUntaggedTag, but have other tags too
    Fix: sil REBUILD"
        problems=$(( problems + 1 ))
    fi

    if ! dayLinksCorrect; then
        msgWarn "[!] Date tag next/previous links are out of date (eg after a git merge)
    Fix: sil REBUILD"
        problems=$(( problems + 1 ))
    fi

    if (( problems )); then
        msgWarn "[!] $problems problem(s) found in ${#stored[@]} stored images"
        return 1
    fi
    msgInfo "No problems found in ${#stored[@]} stored images"
}
