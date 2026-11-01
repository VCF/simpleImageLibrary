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
        ! -path "$(sourcesFile)" | sort
}

## Moves made by repairStoredImages: old absolute path -> new absolute
## path. Read by retargetTagLinks
declare -gA _silMoved=()

#######################################
# Give every stored image its correct name and place (REQ-05): named by
# its current sha1sum, with the suffix of its current format, in its
# images/xx/yy/ folder. Fixes images edited after storage, misplaced
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
    mv -- "$new" "$(indexFile)"
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
# REBUILD (REQ-09): restore missing library files, repair stored image
# names and places while keeping their tags and sources, relink the
# date tag's days, then regenerate the fingerprint index.
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
    requireTool ffmpeg ffmpeg "fingerprint stored animations (GIF, AVIF)"
    local rv=0
    msgInfo "Rebuilding library: $SIL_LIBRARY"
    libraryEnsureFiles "$SIL_LIBRARY"
    repairStoredImages || rv=1
    retargetTagLinks
    retargetSources || rv=1
    relinkDays
    indexRebuild || rv=1
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
    local problems=0 indexProblems=0 n=0
    local -A stored=() indexed=()
    local f rel name hash dir expected actual
    local index line lineNum=0

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
        expected="images/${hash:0:2}/${hash:2:2}"
        dir="$(dirname -- "$rel")"
        if [[ "$dir" != "$expected" ]]; then
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
                msgWarn "[!] Malformed sources line $lineNum: $line"
                problems=$(( problems + 1 ))
            elif [[ -z "${stored[${BASH_REMATCH[1]}]:-}" ]]; then
                msgWarn "[!] Source recorded for an image that isn't stored: $line
    Fix: if the image was removed on purpose, remove this line from images/sources.txt"
                problems=$(( problems + 1 ))
            fi
        done < "$(sourcesFile)"
    fi

    while IFS= read -r f; do
        msgWarn "[!] Broken tag link: ${f#"$SIL_LIBRARY"/} -> $(readlink -- "$f")
    Fix: remove the link"
        problems=$(( problems + 1 ))
    done < <(find "$SIL_LIBRARY/tags" -xtype l 2> /dev/null | sort)

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
