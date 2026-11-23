## Copying and moving images between libraries - see COPY and MOVE in
## docs/parameters.md, and REQ-14

srcLib "params"
srcLib "library"
srcLib "ingest"

## The COPY or MOVE block a manifest is in: COPY, MOVE, or empty outside one
declare -g _silCopyMode=""

## The block's source and target libraries (absolute paths), and why its
## hashes can't be copied, if they can't (eg the target is not a library)
declare -g _silCopySource="" _silCopyTarget="" _silCopyProblem=""

## Target that WebSIL writes in its blocks, for the user to replace
declare -g _silCopyPlaceholder="update/this/path/to/your/desired/destination/library"

## Matches the arrow between source and target in a block's line
declare -g _silCopyArrowRe='^(.*[^[:space:]])?[[:space:]]+(->|>)[[:space:]]+(.*)$'

#######################################
# Test whether a manifest line starts a COPY or MOVE block, eg
# 'COPY ~/lib -> ~/other' or 'MV=~/other', and split it. A line naming an
# existing file is a URI, not a block, so 'copy of cat.jpg' still loads.
# Arguments:
#   $1 - Manifest line, trimmed
#   $2 - Folder that relative paths are relative to
#   $3 - Name of the variable to set to COPY or MOVE
#   $4 - Name of the variable to set to the rest of the line
# Returns:
#   0 if the line starts a block, 1 otherwise
#######################################
function copyBlockLine {
    local _line="$1" _base="$2" _canon
    [[ "$_line" =~ ^([A-Za-z]+)([[:space:]]*=[[:space:]]*|[[:space:]]+|$)(.*)$ ]] || return 1
    printf -v "$4" '%s' "${BASH_REMATCH[3]}"
    _canon="$(paramCanonical "${BASH_REMATCH[1]}")" || return 1
    [[ "$_canon" == COPY || "$_canon" == MOVE ]] || return 1
    [[ -e "$_base/$_line" ]] && return 1
    printf -v "$3" '%s' "$_canon"
}

#######################################
# Resolve a library path from a COPY or MOVE line: quotes removed, '~'
# expanded, and relative paths taken from the manifest's folder.
# Globals:
#   HOME
# Arguments:
#   $1 - Path as written
#   $2 - Folder that relative paths are relative to
# Outputs:
#   Absolute path to STDOUT
#######################################
function copyLibraryPath {
    local path base="$2"
    path="$(unquote "$(trim "$1")")"
    # shellcheck disable=SC2088  # Matching a literal, unexpanded '~'
    [[ "$path" == "~" || "$path" == "~/"* ]] && path="$HOME${path:1}"
    [[ "$path" == /* ]] || path="$base/$path"
    realpath -m -- "$path"
}

#######################################
# Check a COPY or MOVE source or target is a library this run can use,
# locking it (REQ-12) for the rest of the run. Its web page's stamp is
# updated at exit if the run changes it (stampChangedLibraries). Unlike
# LIBRARY, a library is never created here: a mistyped target would
# otherwise quietly gather the images. Not to be run in a subshell, which
# would release the lock as it ends.
# Globals:
#   _silCopyPlaceholder
# Arguments:
#   $1 - 'source' or 'target', for messages
#   $2 - Path as written, for messages
#   $3 - Absolute path
#   $4 - Name of the variable to set to why it can't be used
# Outputs:
#   Who holds the lock, to STDERR, if another sil does
# Returns:
#   0 if usable, 1 otherwise
#######################################
function copyLibraryProblem {
    local _role="$1" _given="$2" _lib="$3" _problemVar="$4"
    if [[ "$_given" == *"$_silCopyPlaceholder"* ]]; then
        printf -v "$_problemVar" 'The %s is still the placeholder WebSIL wrote: replace it with the path of a library' "$_role"
    elif [[ ! -e "$_lib" ]]; then
        printf -v "$_problemVar" 'The %s library does not exist: %s' "$_role" "$_lib"
    elif ! isLibrary "$_lib"; then
        printf -v "$_problemVar" "The %s is not a SIL library (a folder with 'images' and 'tags'): %s" "$_role" "$_lib"
    elif ! lockLibrary "$_lib" try; then
        printf -v "$_problemVar" 'The %s library is in use by another sil: %s' "$_role" "$_lib"
    elif ! layoutProblem "$_lib" > /dev/null; then
        printf -v "$_problemVar" "The %s library's images are in an image layout this sil can't use. See: sil LIBRARY='%s' CHECK" "$_role" "$_lib"
    else
        return 0
    fi
    return 1
}

#######################################
# End any COPY or MOVE block.
# Globals:
#   Sets _silCopyMode, _silCopySource, _silCopyTarget, _silCopyProblem;
#   unsets SIL_COPY, SIL_MOVE
#######################################
function closeCopyBlock {
    _silCopyMode=""
    _silCopySource=""
    _silCopyTarget=""
    _silCopyProblem=""
    unset SIL_COPY SIL_MOVE
}

#######################################
# Start a COPY or MOVE block in a manifest, for the hashes on the lines
# after it. The value is 'SOURCE -> TARGET' ('>' also serves as the
# arrow), or just TARGET, the source then being the library in use. Each
# must be an existing library, other than the other. If not, the warning
# says why, and the block's hashes fail (NOLIBRARY), so the error log
# has them ready to retry. An empty value just ends any block.
# SIL_COPY (or SIL_MOVE) holds the block's line while it lasts, so the
# error log writes it before the block's failures (logSettings).
# Globals:
#   SIL_LIBRARY; sets _silCopyMode, _silCopySource, _silCopyTarget,
#   _silCopyProblem, SIL_COPY or SIL_MOVE
# Arguments:
#   $1 - COPY or MOVE
#   $2 - Value, eg '~/lib -> ~/other'
#   $3 - Folder that relative paths are relative to
#   $4 - Location of the line, for messages
# Outputs:
#   The block's libraries, or why its hashes will fail, to STDERR
# Returns:
#   0 if the block can be carried out (or just ended), 1 otherwise
#######################################
function openCopyBlock {
    local mode="$1" value="$2" base="$3" where="$4"
    local srcGiven="" tgtGiven src="" tgt problem=""
    closeCopyBlock
    value="$(trim "$value")"
    [[ -n "$value" ]] || return 0

    if [[ " $value " =~ $_silCopyArrowRe ]]; then
        srcGiven="$(trim "${BASH_REMATCH[1]}")"
        tgtGiven="$(trim "${BASH_REMATCH[3]}")"
    else
        tgtGiven="$value"
    fi
    _silCopyMode="$mode"

    if [[ -n "$srcGiven" ]]; then
        src="$(copyLibraryPath "$srcGiven" "$base")"
    elif [[ -n "${SIL_LIBRARY:-}" ]]; then
        src="$SIL_LIBRARY"
        srcGiven="$src"
    else
        problem="No source library: give one, as $mode SOURCE -> TARGET, or set LIBRARY"
    fi
    if [[ -z "$tgtGiven" ]]; then
        problem="No target library: give one, as $mode SOURCE -> TARGET"
    else
        tgt="$(copyLibraryPath "$tgtGiven" "$base")"
    fi

    if [[ -z "$problem" ]]; then
        if copyLibraryProblem source "$srcGiven" "$src" problem \
            && copyLibraryProblem target "$tgtGiven" "$tgt" problem; then
            [[ "$src" == "$tgt" ]] && problem="The source and target are the same library: $src"
        fi
    fi

    ## Written as given if not usable, so the user sees their own text to fix
    if [[ -z "$problem" ]]; then
        printf -v "SIL_$mode" '%s -> %s' "$src" "$tgt"
        _silCopySource="$src"
        _silCopyTarget="$tgt"
        msgInfo "  $mode $src -> $tgt (line ${where##* line })"
        return 0
    fi
    printf -v "SIL_$mode" '%s -> %s' "$srcGiven" "$tgtGiven"
    _silCopyProblem="$problem"
    msgWarn "[!] $mode can't be carried out: $problem
    The hashes after it fail as NOLIBRARY, and go to the error log for a retry
    once the line is corrected. Libraries must already exist, and differ
    Found in: $where"
    return 1
}

#######################################
# The user tags of a stored image (userTagLinks), as tag paths.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Image hash
# Outputs:
#   One tag path per line to STDOUT, sorted
#######################################
function userTagPaths {
    local root link
    root="$(realpath -- "$SIL_LIBRARY/tags")"
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        link="$(dirname -- "$link")"
        printf '%s\n' "${link#"$root"/}"
    done < <(userTagLinks "$1") | LC_ALL=C sort -u
}

#######################################
# Copy, or move, one stored image to the target library of the current
# block (REQ-14). In the target it is added as a new image would be, with
# the target's settings (SHRINK, THRESHOLD, KEEPLARGER etc, from its
# sil.conf, then the command line and the manifest's settings so far): a
# duplicate isn't stored again, but gains the copy's tags and sources. A
# newly stored copy is dated today. The copy gets every user tag of the
# original (through the target's REMAP), and its recorded sources. TAG,
# UNTAG and REMOVE don't apply. A MOVE then removes the original, unless
# anything about the copy failed.
# Globals:
#   _silCopyMode, _silCopySource, _silCopyTarget, _silCopyProblem; SIL_<NAME>
#   are changed, then restored
# Arguments:
#   $1 - Image hash, in the source library
#   $2 - Manifest line number, shown before the hash
#   $@ - The manifest's NAME=VALUE settings so far (reloadParamsForLibrary)
# Outputs:
#   Progress and the outcome to STDERR
# Returns:
#   0 on success, 1 on failure; halts (msgError) if needed tools are
#   missing
#######################################
function copyStored {
    local hash="${1,,}" lineNum="$2"
    local mode="$_silCopyMode" src="$_silCopySource" tgt="$_silCopyTarget"
    local srcFile tmp source rv=0 isNew=0 newHash outcome detail verb
    local -a tags sources
    local -A _copySaved=()
    shift 2
    verb="copied"
    [[ "$mode" == MOVE ]] && verb="moved"
    msgInfo "${lineNum:+[$lineNum] }$hash"
    if [[ -n "$_silCopyProblem" ]]; then
        reportOutcome NOLIBRARY "Not $verb: $_silCopyProblem"
        return 1
    fi
    requireImageTools

    saveParams _copySaved
    reloadParamsForLibrary "$src" "$@"
    if ! srcFile="$(findStoredImage "$hash")"; then
        restoreParams _copySaved
        reportOutcome NOHASH "No image with this hash in the source library, $src"
        return 1
    fi
    mapfile -t tags < <(userTagPaths "$hash")
    mapfile -t sources < <(sourcesOf "$hash")

    reloadParamsForLibrary "$tgt" "$@"
    syncRemaps || rv=1
    msgStatus "  Copying to $tgt"
    if ! fetchURI "$srcFile" tmp; then
        restoreParams _copySaved
        reportOutcome "$_silFetchReason" "Not $verb: $_silFetchDetail"
        return 1
    fi
    if ! ingestFile "$tmp" "$srcFile"; then
        rm -f -- "$tmp"
        restoreParams _copySaved
        reportOutcome "$_silOutcome" "Not $verb: $_silOutcomeDetail"
        return 1
    fi
    rm -f -- "$tmp"
    newHash="$_silOutcomeHash"
    outcome="$_silOutcome"
    detail="$_silOutcomeDetail"

    for source in "${sources[@]}"; do
        if ! sourceRecord "$newHash" "$source"; then
            msgWarn "[!] Could not record its sources in $(sourcesFile)"
            rv=1
            break
        fi
    done
    if [[ "$outcome" == ADDED || "$outcome" == SHRINK ]]; then
        isNew=1
        dateTagImage "$newHash" || { msgWarn "[!] Could not apply the date tag"; rv=1; }
    fi
    ## Applied as a TAG, so the target's REMAPs and tag rules apply
    # shellcheck disable=SC2034  # Read by applyTags, in src/tags.sh
    printf -v SIL_TAG '%s' "$(IFS=,; printf '%s' "${tags[*]}")"
    applyTags "$newHash" || rv=1
    if (( isNew && _silTagsApplied == 0 )); then
        markUntagged "$newHash" || { msgWarn "[!] Could not apply the $_silUntaggedTag tag"; rv=1; }
    fi

    detail="$tgt: $outcome $detail"
    if [[ "$mode" == MOVE ]]; then
        if (( rv )); then
            restoreParams _copySaved
            reportOutcome NOTMOVED "Copied ($detail), but kept in the source, as the copy is incomplete; run again to finish" "$newHash"
            return 1
        fi
        reloadParamsForLibrary "$src" "$@"
        if ! removeImage "$hash"; then
            restoreParams _copySaved
            reportOutcome NOTMOVED "Copied ($detail), but could not be removed from the source" "$newHash"
            return 1
        fi
    fi
    restoreParams _copySaved
    reportOutcome "${verb^^}" "$detail" "$newHash"
    return "$rv"
}
