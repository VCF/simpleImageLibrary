## Adding images: the per-URI pipeline and outcome reporting (REQ-08)

srcLib "fetch"
srcLib "shrink"
srcLib "tags"
srcLib "replace"

## Successful outcome tags, in reporting order; anything else is a failure
declare -ga _silSuccessTags=(ADDED SHRINK UPGRADED REFETCHED DUPE FOUND REMOVED COPIED MOVED)

## Outcome tag -> count, for the run summary
declare -gA _silOutcomes=()

## Set by ingestFile: outcome tag, explanation, and image hash
declare -g _silOutcome="" _silOutcomeDetail="" _silOutcomeHash=""

## Set by reportOutcome: the most recent URI's outcome, for manifest logs
declare -g _silLastOutcome="" _silLastDetail="" _silLastHash=""

#######################################
# Test whether an outcome tag is a success.
# Arguments:
#   $1 - Outcome tag
# Returns:
#   0 if a success, 1 if a failure
#######################################
function isSuccessTag {
    local tag
    for tag in "${_silSuccessTags[@]}"; do
        [[ "$1" == "$tag" ]] && return 0
    done
    return 1
}

#######################################
# Count and report the outcome for a URI.
# Globals:
#   _silOutcomes; sets _silLastOutcome, _silLastDetail, _silLastHash
# Arguments:
#   $1 - Outcome tag (REQ-08), eg ADDED or NOTFOUND
#   $2 - Explanation (optional)
#   $3 - Hash of the resulting image (optional)
# Outputs:
#   One line to STDERR: msgInfo for success, msgWarn for failure
#######################################
function reportOutcome {
    _silLastOutcome="$1"
    _silLastDetail="${2:-}"
    _silLastHash="${3:-}"
    _silOutcomes[$1]=$(( ${_silOutcomes[$1]:-0} + 1 ))
    if isSuccessTag "$1"; then
        msgInfo "  [$1]${2:+ $2}"
    else
        msgWarn "  [!] [$1]${2:+ $2}"
    fi
}

#######################################
# Set the outcome of ingestFile.
# Globals:
#   Sets _silOutcome, _silOutcomeDetail
# Arguments:
#   $1 - Outcome tag
#   $2 - Explanation
# Returns:
#   0 for a success tag, 1 for a failure
#######################################
function setOutcome {
    _silOutcome="$1"
    _silOutcomeDetail="$2"
    isSuccessTag "$1"
}

#######################################
# Add a recovered file to the library (REQ-05, REQ-07): check it is a
# supported image, shrink it, then store it, or match it to a similar
# stored image, which KEEPLARGER may replace with it. Given an image to
# replace (REFETCH of a hash), the file must match that image, and then
# replaces it whatever its size; anything else is NOMATCH. Temporary files
# made here are removed; the input file is left for the caller.
# Globals:
#   SIL_THRESHOLD, SIL_KEEPLARGER; sets _silOutcome, _silOutcomeDetail,
#   _silOutcomeHash
# Arguments:
#   $1 - Recovered file (in the library's temp folder, no suffix)
#   $2 - The URI it came from, for the record of any replacement
#   $3 - Hash of the stored image it should replace (optional)
# Returns:
#   0 if added or matched, 1 on failure
#######################################
function ingestFile {
    local file="$1" source="$2" replace="${3:-}"
    local format rc kept fp match hash mime
    _silOutcomeHash=""

    msgStatus "  Checking image"
    format="$(imageFormat "$file")"
    rc=$?
    case "$rc" in
        0) ;;
        2) setOutcome BADIMAGE "Damaged $format image"; return ;;
        3) setOutcome UNSUPPORTED "$format images are not supported"; return ;;
        *)
            mime="$(file -b --mime-type -- "$file" 2> /dev/null)"
            setOutcome NOTIMAGE "Not an image${mime:+ ($mime)}"
            return
            ;;
    esac

    if ! shrinkImage "$file" kept; then
        setOutcome SHRINKFAIL "$_silShrinkFailDetail"
        return
    fi
    msgStatus "  Fingerprinting"
    if ! fp="$(imageFingerprint "$kept")"; then
        [[ "$kept" != "$file" ]] && rm -f -- "$kept"
        setOutcome BADIMAGE "Could not be fingerprinted"
        return
    fi

    msgStatus "  Comparing with library"
    if [[ -n "$replace" ]]; then
        match="$(indexMatch "$fp" "$SIL_THRESHOLD" | awk -v h="$replace" '$2 == h' | head -n 1)"
        if [[ -n "$match" ]]; then
            _silOutcomeHash="$replace"
            setOutcome DUPE "${replace:0:12} - unchanged"
            refetchReplace "$kept" "$fp" "${match%% *}" "$source"
        else
            setOutcome NOMATCH "No longer matches ${replace:0:12} (THRESHOLD $SIL_THRESHOLD%); left unchanged"
        fi
    elif match="$(indexMatch "$fp" "$SIL_THRESHOLD" | head -n 1)" && [[ -n "$match" ]]; then
        _silOutcomeHash="${match#* }"
        setOutcome DUPE "${_silOutcomeHash:0:12} - already in library (${match%% *} of 256 bits differ)"
        if flagIsSet KEEPLARGER; then
            keepLarger "$kept" "$fp" "${match%% *}" "$source"
        fi
    elif storeImage "$kept" hash "$fp"; then
        _silOutcomeHash="$hash"
        if [[ "$kept" != "$file" ]]; then
            setOutcome SHRINK "${hash:0:12}${_silShrinkNote:+ - $_silShrinkNote}"
        else
            setOutcome ADDED "${hash:0:12}${_silShrinkNote:+ - $_silShrinkNote}"
        fi
    else
        setOutcome STOREFAIL "Could not write to the library"
    fi
    rc=$?
    [[ "$kept" != "$file" ]] && rm -f -- "$kept"
    return "$rc"
}

#######################################
# Find the stored image a URI already identifies, without downloading:
# a URL recorded as a source, or a local file identical to a stored
# image (same hash; a shrunk image differs from its original).
# Arguments:
#   $1 - URI kind, from uriKind: url or path
#   $2 - The URL, or the local path (resolved against any base folder)
# Outputs:
#   The image hash to STDOUT
# Returns:
#   0 if found, 1 otherwise
#######################################
function knownImage {
    local hash
    case "$1" in
        url)
            sourceLookup "$2"
            ;;
        path)
            [[ -f "$2" && -r "$2" ]] || return 1
            msgStatus "  Looking for the same file in the library"
        hash="$(fileHash "$2")" && findStoredImage "$hash" > /dev/null || return 1
            printf '%s\n' "$hash"
            ;;
        *)
            return 1
            ;;
    esac
}

#######################################
# Act on a stored image that a URI identified: remove it (REMOVE), or
# report it FOUND and apply SIL_UNTAG then SIL_TAG, so that
# 'TAG=New UNTAG=*' replaces every tag with New.
# Globals:
#   SIL_REMOVE, SIL_TAG, SIL_UNTAG
# Arguments:
#   $1 - Image hash
#   $2 - How it was identified, for the FOUND report (optional)
# Outputs:
#   The outcome and changes to STDERR
# Returns:
#   0 on success, 1 on failure
#######################################
function updateStored {
    local hash="$1" rv=0
    if flagIsSet REMOVE; then
        if removeImage "$hash"; then
            reportOutcome REMOVED "${hash:0:12}" "$hash"
            return 0
        fi
        reportOutcome STOREFAIL "Could not remove ${hash:0:12} from the library" "$hash"
        return 1
    fi
    reportOutcome FOUND "${hash:0:12}${2:+ - $2}" "$hash"
    applyUntags "$hash" || rv=1
    applyTags "$hash" || rv=1
    return "$rv"
}

#######################################
# Download a stored image again from its recorded URL sources, and replace
# it with the download (REFETCH of a hash), with the SHRINK now in force.
# With more than one source, the person running SIL chooses, from a list
# newest first (askChoice), as a later source is likely the better copy.
# With no terminal to ask at, they are tried newest first until one
# downloads. The download must match
# the image by fingerprint (NOMATCH otherwise), as a site may now serve
# something else; it then replaces the image whatever its size, keeping its
# tags, date and sources (refetchReplace). SIL_UNTAG and SIL_TAG are then
# applied, as for FOUND.
# Globals:
#   SIL_THRESHOLD, SIL_TAG, SIL_UNTAG
# Arguments:
#   $1 - Image hash
# Outputs:
#   Progress and the outcome to STDERR
# Returns:
#   0 on success, 1 on failure
#######################################
function refetchStored {
    local hash="$1" url tmp="" rv choice
    local -a urls
    mapfile -t urls < <(sourcesOf "$hash" | tac | awk '!seen[$0]++' | while IFS= read -r url; do
        [[ "$(uriKind "$url")" == url ]] && printf '%s\n' "$url"
    done)
    if (( ! ${#urls[@]} )); then
        reportOutcome NOSOURCE "${hash:0:12} has no URL source to download again; left unchanged" "$hash"
        return 1
    fi
    if (( ${#urls[@]} > 1 )); then
        if askChoice choice "Multiple sources available for REFETCH on hash ${hash:0:12}.
Please choose URL to fetch (shown newest to oldest):" "${urls[@]:0:26}"; then
            urls=("${urls[choice]}")
        else
            msgInfo "  ${#urls[@]} sources, and no terminal to choose at: trying newest first"
        fi
    fi
    for url in "${urls[@]}"; do
        msgInfo "  Refetching $url"
        fetchURI "$url" tmp && break
        msgWarn "  [!] $_silFetchReason: $_silFetchDetail"
        tmp=""
    done
    if [[ -z "$tmp" ]]; then
        reportOutcome "$_silFetchReason" "No source of ${hash:0:12} could be downloaded; left unchanged" "$hash"
        return 1
    fi

    ingestFile "$tmp" "$url" "$hash"
    rv=$?
    rm -f -- "$tmp"
    reportOutcome "$_silOutcome" "$_silOutcomeDetail" "$_silOutcomeHash"
    (( rv == 0 )) || return 1
    rv=0
    applyUntags "$_silOutcomeHash" || rv=1
    applyTags "$_silOutcomeHash" || rv=1
    return "$rv"
}

#######################################
# Make sure the tools for adding images are installed.
# Returns:
#   0 if they are; halts (msgError) with install instructions otherwise
#######################################
function requireImageTools {
    requireTool identify imagemagick "inspect images"
    requireTool findimagedupes findimagedupes "fingerprint images"
    requireTool ffmpeg ffmpeg "fingerprint animations and videos"
}

#######################################
# Process one URI (REQ-03): a hash selects a stored image, which REFETCH
# downloads again from its sources (refetchStored); a URL already
# recorded as a source is a DUPE of its image, unless REFETCH; any other
# URL or local path is recovered and added. The URI is recorded as a source of
# the resulting image (REQ-05), a newly stored image gets today's date
# tag (TAG-02), and tags in SIL_TAG are applied; a newly stored image
# given none is tagged Untagged (TAG-03). A DUPE or its replacement
# (KEEPLARGER) keeps the tags already there. The outcome is reported and
# counted.
# With REMOVE or UNTAG, the URI must identify an image already stored
# (knownImage), which is then removed or untagged; nothing is downloaded.
# Globals:
#   SIL_TAG, SIL_UNTAG, SIL_REMOVE, SIL_THRESHOLD, SIL_REFETCH,
#   SIL_KEEPLARGER
# Arguments:
#   $1 - URI
#   $2 - Folder that relative paths are relative to (default: current
#        folder; a manifest's folder for manifests, REQ-06)
#   $3 - Optional manifest line number, shown before the URI as '[7]'
# Outputs:
#   Progress and the outcome to STDERR
# Returns:
#   0 on success, 1 on failure; halts (msgError) if needed tools are
#   missing
#######################################
function processURI {
    local uri="$1" base="${2:-}" lineNum="${3:-}"
    local kind path tmp hash rv isNew=0
    msgInfo "${lineNum:+[$lineNum] }$uri"
    requireImageTools

    kind="$(uriKind "$uri")"
    path="$uri"
    if [[ "$kind" == path && -n "$base" && "$path" != /* ]]; then
        path="$base/$path"
    fi

    if [[ "$kind" == hash ]]; then
        if ! findStoredImage "$uri" > /dev/null; then
            reportOutcome NOHASH "No image with this hash in the library"
            return 1
        fi
        if flagIsSet REFETCH && ! flagIsSet REMOVE; then
            refetchStored "${uri,,}"
        else
            updateStored "${uri,,}"
        fi
        return
    fi

    if flagIsSet REMOVE || [[ -n "${SIL_UNTAG:-}" ]]; then
        if ! hash="$(knownImage "$kind" "$path")"; then
            reportOutcome NOTSTORED "Not a known source or stored file; REMOVE and UNTAG never download"
            return 1
        fi
        updateStored "$hash" "$([[ "$kind" == url ]] && echo "a known source" || echo "same file")"
        return
    fi

    ## A URL already recorded as a source is a DUPE, without downloading,
    ## unless REFETCH. Not for local files: they are recorded by name only
    if [[ "$kind" == url ]] && ! flagIsSet REFETCH && hash="$(sourceLookup "$uri")"; then
        reportOutcome DUPE "${hash:0:12} - known source, not downloaded (REFETCH to check)" "$hash"
        applyTags "$hash"
        return
    fi

    if ! fetchURI "$path" tmp; then
        reportOutcome "$_silFetchReason" "$_silFetchDetail"
        return 1
    fi

    ingestFile "$tmp" "$uri"
    rv=$?
    rm -f -- "$tmp"
    reportOutcome "$_silOutcome" "$_silOutcomeDetail" "$_silOutcomeHash"
    (( rv == 0 )) || return 1

    sourceAdd "$_silOutcomeHash" "$uri" \
        || msgWarn "[!] Could not record the source in $(sourcesFile)"
    rv=0
    [[ "$_silOutcome" == ADDED || "$_silOutcome" == SHRINK ]] && isNew=1
    if (( isNew )); then
        dateTagImage "$_silOutcomeHash" || { msgWarn "[!] Could not apply the date tag"; rv=1; }
    fi
    applyTags "$_silOutcomeHash" || rv=1
    if (( isNew && _silTagsApplied == 0 )); then
        if markUntagged "$_silOutcomeHash"; then
            msgInfo "  Tagged: $_silUntaggedTag"
        else
            msgWarn "[!] Could not apply the $_silUntaggedTag tag"
            rv=1
        fi
    fi
    return "$rv"
}

#######################################
# Report the totals of all outcomes so far, the tags added and removed
# (as +added/-removed TAGGED, '/-removed' only when some were), and how
# long they took.
# Globals:
#   _silOutcomes, _silSuccessTags, _silTagsAdded, _silTagsRemoved
# Arguments:
#   $1 - Optional start mark (clockMark); adds the elapsed time
# Outputs:
#   Summary lines to STDERR
#######################################
function outcomeSummary {
    local tag ok="" failed="" nFailed=0
    for tag in "${_silSuccessTags[@]}"; do
        [[ -n "${_silOutcomes[$tag]:-}" ]] && ok="${ok:+$ok, }${_silOutcomes[$tag]} $tag"
    done
    for tag in $(printf '%s\n' "${!_silOutcomes[@]}" | sort); do
        isSuccessTag "$tag" && continue
        failed="${failed:+$failed, }${_silOutcomes[$tag]} $tag"
        nFailed=$(( nFailed + _silOutcomes[$tag] ))
    done
    if (( _silTagsAdded || _silTagsRemoved )); then
        tag="+$_silTagsAdded"
        (( _silTagsRemoved )) && tag="$tag/-$_silTagsRemoved"
        ok="${ok:+$ok, }$tag TAGGED"
    fi
    msgInfo "Done: ${ok:-nothing added}${1:+. $(elapsedText "$1")}"
    (( nFailed )) && msgWarn "[!] $nFailed failed: $failed"
    return 0
}
