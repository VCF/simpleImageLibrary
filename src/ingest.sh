## Adding images: the per-URI pipeline and outcome reporting (REQ-08)

srcLib "fetch"
srcLib "shrink"
srcLib "tags"

## Successful outcome tags, in reporting order; anything else is a failure
declare -ga _silSuccessTags=(ADDED SHRINK DUPE FOUND REMOVED)

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
# stored image. Temporary files made here are removed; the input file
# is left for the caller.
# Globals:
#   SIL_THRESHOLD; sets _silOutcome, _silOutcomeDetail, _silOutcomeHash
# Arguments:
#   $1 - Recovered file (in the library's temp folder, no suffix)
# Returns:
#   0 if added or matched, 1 on failure
#######################################
function ingestFile {
    local file="$1"
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
    match="$(indexMatch "$fp" "$SIL_THRESHOLD" | head -n 1)"
    if [[ -n "$match" ]]; then
        _silOutcomeHash="${match#* }"
        setOutcome DUPE "${_silOutcomeHash:0:12} - already in library (${match%% *} of 256 bits differ)"
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
# Process one URI (REQ-03): a hash selects a stored image; a URL already
# recorded as a source is a DUPE of its image, unless REFETCH; any other
# URL or local path is recovered and added. The URI is recorded as a source of
# the resulting image (REQ-05), a newly stored image gets today's date
# tag (TAG-02), and tags in SIL_TAG are applied; a newly stored image
# given none is tagged Untagged (TAG-03). The outcome is reported and
# counted.
# With REMOVE or UNTAG, the URI must identify an image already stored
# (knownImage), which is then removed or untagged; nothing is downloaded.
# Globals:
#   SIL_TAG, SIL_UNTAG, SIL_REMOVE, SIL_THRESHOLD, SIL_REFETCH
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
    local kind path tmp hash rv
    msgInfo "${lineNum:+[$lineNum] }$uri"
    requireTool identify imagemagick "inspect images"
    requireTool findimagedupes findimagedupes "fingerprint images"
    requireTool ffmpeg ffmpeg "fingerprint animations (GIF, AVIF)"

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
        updateStored "${uri,,}"
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

    ingestFile "$tmp"
    rv=$?
    rm -f -- "$tmp"
    reportOutcome "$_silOutcome" "$_silOutcomeDetail" "$_silOutcomeHash"
    (( rv == 0 )) || return 1

    sourceAdd "$_silOutcomeHash" "$uri" \
        || msgWarn "[!] Could not record the source in $(sourcesFile)"
    rv=0
    if [[ "$_silOutcome" != DUPE ]]; then
        dateTagImage "$_silOutcomeHash" || { msgWarn "[!] Could not apply the date tag"; rv=1; }
    fi
    applyTags "$_silOutcomeHash" || rv=1
    if [[ "$_silOutcome" != DUPE ]] && (( _silTagsApplied == 0 )); then
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
# Report the totals of all outcomes so far.
# Globals:
#   _silOutcomes, _silSuccessTags
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
    msgInfo "Done: ${ok:-nothing added}"
    (( nFailed )) && msgWarn "[!] $nFailed failed: $failed"
    return 0
}
