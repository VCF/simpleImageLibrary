## Adding images: the per-URI pipeline and outcome reporting (REQ-08)

srcLib "fetch"
srcLib "shrink"
srcLib "tags"

## Successful outcome tags, in reporting order; anything else is a failure
declare -ga _silSuccessTags=(ADDED SHRINK DUPE FOUND)

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

    shrinkImage "$file" kept
    if ! fp="$(imageFingerprint "$kept")"; then
        [[ "$kept" != "$file" ]] && rm -f -- "$kept"
        setOutcome BADIMAGE "Could not be fingerprinted"
        return
    fi

    match="$(indexMatch "$fp" "$SIL_THRESHOLD" | head -n 1)"
    if [[ -n "$match" ]]; then
        _silOutcomeHash="${match#* }"
        setOutcome DUPE "${_silOutcomeHash:0:12}, already in library (${match%% *} of 256 bits differ)"
    elif storeImage "$kept" hash "$fp"; then
        _silOutcomeHash="$hash"
        if [[ "$kept" != "$file" ]]; then
            setOutcome SHRINK "${hash:0:12}"
        else
            setOutcome ADDED "${hash:0:12}"
        fi
    else
        setOutcome STOREFAIL "Could not write to the library"
    fi
    rc=$?
    [[ "$kept" != "$file" ]] && rm -f -- "$kept"
    return "$rc"
}

#######################################
# Process one URI (REQ-03): a hash selects a stored image; a URL or
# local path is recovered and added. The URI is recorded as a source of
# the resulting image (REQ-05), a newly stored image gets today's date
# tag (TAG-02), and tags in SIL_TAG are applied. The outcome is reported
# and counted.
# Globals:
#   SIL_TAG, SIL_THRESHOLD
# Arguments:
#   $1 - URI
#   $2 - Folder that relative paths are relative to (default: current
#        folder; a manifest's folder for manifests, REQ-06)
# Outputs:
#   Progress and the outcome to STDERR
# Returns:
#   0 on success, 1 on failure; halts (msgError) if needed tools are
#   missing
#######################################
function processURI {
    local uri="$1" base="${2:-}"
    local kind path tmp hash rv
    msgInfo "$uri"
    requireTool identify imagemagick "inspect images"
    requireTool findimagedupes findimagedupes "fingerprint images"

    kind="$(uriKind "$uri")"
    if [[ "$kind" == hash ]]; then
        if ! findStoredImage "$uri" > /dev/null; then
            reportOutcome NOHASH "No image with this hash in the library"
            return 1
        fi
        hash="${uri,,}"
        reportOutcome FOUND "${hash:0:12}" "$hash"
        applyTags "$hash"
        return
    fi

    path="$uri"
    if [[ "$kind" == path && -n "$base" && "$path" != /* ]]; then
        path="$base/$path"
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
