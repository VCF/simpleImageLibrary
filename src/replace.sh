## Replacing a stored image with a larger duplicate - see KEEPLARGER in
## docs/parameters.md

srcLib "tags"

## Record of replacements, and the replaced files, in a library's root
declare -g _silReplacedLog="ReplacedImages.tsv"
declare -g _silReplacedDir="replacedWithHigherRes"

#######################################
# Add a line to a text file, unless it is already there.
# Arguments:
#   $1 - File path; created if missing
#   $2 - The line
# Returns:
#   0 on success, 1 if the file can't be written
#######################################
function ensureFileLine {
    grep -qxF -- "$2" "$1" 2> /dev/null && return 0
    ## $(...) drops a final newline, so this is only non-empty without one
    if [[ -n "$(tail -c 1 -- "$1" 2> /dev/null)" ]]; then
        printf '\n' >> "$1" || return 1
    fi
    printf '%s\n' "$2" >> "$1"
}

#######################################
# Record a replacement in the library's log, one line per source of the
# replaced image, so that each stands alone for grep and git merges. Tabs
# in a source, possible in a local file name, become spaces.
# Globals:
#   SIL_LIBRARY, _silReplacedLog
# Arguments:
#   $1 - Hash of the replaced image, whose sources are still recorded
#   $2 - Hash of its replacement
#   $3 - Size of the replaced image, as WIDTHxHEIGHT
#   $4 - Size of its replacement
#   $5 - Fingerprint bits differing between them
#   $6 - Source of the replacement, as a URL or local path
# Returns:
#   0 on success, 1 if the log can't be written
#######################################
function replacedLogAdd {
    local file="$SIL_LIBRARY/$_silReplacedLog"
    local day high low
    local -a lows
    if [[ ! -s "$file" ]]; then
        printf 'date\toldHash\tnewHash\toldWxH\tnewWxH\tbitsDiffering\tlowResURL\thighResURL\n' \
            > "$file" || return 1
    fi
    day="$(todayDate)"
    high="$(sourceName "$6")"
    mapfile -t lows < <(sourcesOf "$1")
    (( ${#lows[@]} )) || lows=(-)
    for low in "${lows[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$1" "$2" "$3" "$4" "$5" \
            "${low//$'\t'/ }" "${high//$'\t'/ }" >> "$file" || return 1
    done
}

#######################################
# Point all of an image's tag links at another stored image, each renamed
# after its new target. Its date tag is one of these, so the replacement
# keeps the date the image first entered the library.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Path of the stored image the links point to
#   $2 - Path of the stored image they should point to
# Returns:
#   0 on success, 1 if any link could not be replaced
#######################################
function moveTagLinks {
    local old="$1" new="$2" real link dir rv=0
    local -a links
    real="$(realpath -- "$old")"
    mapfile -t links < <(find "$SIL_LIBRARY/tags" -type l -name "${old##*/}")
    for link in "${links[@]}"; do
        [[ "$(realpath -m -- "$link")" == "$real" ]] || continue
        dir="$(dirname -- "$link")"
        rm -f -- "$link" || rv=1
        ln -s -- "$(relativePath "$dir" "$new")" "$dir/${new##*/}" || rv=1
    done
    return "$rv"
}

#######################################
# Move a stored image's tags, sources and place to its replacement, which
# must already be stored. The replaced file is copied to the library's
# replaced folder and logged first, so that nothing is lost if this fails.
# Globals:
#   SIL_LIBRARY, _silReplacedDir, _silReplacedLog
# Arguments:
#   $1 - Hash of the image being replaced
#   $2 - Hash of its replacement
#   $3 - Size of the replaced image, as WIDTHxHEIGHT
#   $4 - Size of its replacement
#   $5 - Fingerprint bits differing between them
#   $6 - Source of the replacement, as a URL or local path
# Returns:
#   0 on success; 1 if the replaced file or log can't be written, with
#   the library unchanged; 2 if its records could not all be updated
#######################################
function replaceStored {
    local old="$1" new="$2"
    local oldFile newFile dir map rv=0
    oldFile="$(findStoredImage "$old")" || return 1
    newFile="$(findStoredImage "$new")" || return 1
    dir="$SIL_LIBRARY/$_silReplacedDir"

    if ! { mkdir -p -- "$dir" \
        && cp -- "$oldFile" "$dir/" \
        && ensureFileLine "$SIL_LIBRARY/.gitignore" "$_silReplacedDir/" \
        && ensureFileLine "$SIL_LIBRARY/.gitattributes" "$_silReplacedLog merge=union" \
        && replacedLogAdd "$old" "$new" "$3" "$4" "$5" "$6"; }; then
        rm -f -- "$dir/${oldFile##*/}"
        return 1
    fi

    moveTagLinks "$oldFile" "$newFile" || rv=2
    map="$(silMktemp)" || return 2
    printf '%s %s\n' "$old" "$new" > "$map"
    sourcesRehash "$map" || rv=2
    rm -f -- "$map"
    indexRemove "$old" || rv=2
    if (( rv == 0 )); then
        rm -f -- "$oldFile"
        find "$SIL_LIBRARY/images" -mindepth 1 -type d -empty -delete
    fi
    return "$rv"
}

#######################################
# Decide what to do with a duplicate under KEEPLARGER: replace the stored
# image it matched if the duplicate has more pixels and both are still,
# or both animated. Otherwise the outcome already set (DUPE) stands.
# Globals:
#   _silOutcomeHash, the image matched; sets _silOutcome,
#   _silOutcomeDetail, _silOutcomeHash
# Arguments:
#   $1 - The duplicate, as it would be stored (after any shrinking)
#   $2 - Its raw fingerprint
#   $3 - Fingerprint bits differing from the stored image
#   $4 - Its source, as a URL or local path
# Returns:
#   0 if the outcome is a success, 1 if replacing failed
#######################################
function keepLarger {
    local file="$1" fp="$2" bits="$3" source="$4"
    local old="$_silOutcomeHash" oldFile oldDims newDims new
    local oldMoves=0 newMoves=0 rc=0
    oldFile="$(findStoredImage "$old")" || return 0
    if ! oldDims="$(imageDimensions "$oldFile")" || ! newDims="$(imageDimensions "$file")"; then
        msgWarn "[!] Could not compare the size of ${old:0:12} and its duplicate; keeping the stored image"
        return 0
    fi
    (( ${newDims%x*} * ${newDims#*x} > ${oldDims%x*} * ${oldDims#*x} )) || return 0

    isAnimated "$oldFile" && oldMoves=1
    isAnimated "$file" && newMoves=1
    if (( oldMoves != newMoves )); then
        _silOutcomeDetail+="; kept although $newDims is larger than $oldDims, as one is animated and the other still"
        return 0
    fi

    ## A closer match can hide the same file, stored under its own hash
    new="$(fileHash "$file")" || return 0
    if findStoredImage "$new" > /dev/null; then
        _silOutcomeHash="$new"
        setOutcome DUPE "${new:0:12} - already in library, unchanged"
        return
    fi

    msgStatus "  Replacing ${old:0:12} ($oldDims) with larger duplicate ($newDims)"
    if ! storeImage "$file" new "$fp"; then
        setOutcome STOREFAIL "Could not write to the library"
        return
    fi
    replaceStored "$old" "$new" "$oldDims" "$newDims" "$bits" "$source" || rc=$?
    case "$rc" in
        0)
            _silOutcomeHash="$new"
            setOutcome UPGRADED "${new:0:12} - replaced ${old:0:12} ($oldDims -> $newDims, $bits of 256 bits differ)"
            ;;
        1)
            removeImage "$new"
            setOutcome STOREFAIL "Could not keep ${old:0:12} in $_silReplacedDir, or log it; left unchanged"
            ;;
        *)
            setOutcome STOREFAIL "Replacing ${old:0:12} with ${new:0:12} did not finish; see sil CHECK"
            ;;
    esac
}
