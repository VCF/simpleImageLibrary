## Manifest logs: <manifest>.err and <manifest>.md - see REQ-08

## Meaning of each outcome tag, for the report legends (REQ-08)
declare -gA _silOutcomeMeaning=(
    [ADDED]="Recovered and added to the library"
    [SHRINK]="Recovered, shrunk and added"
    [DUPE]="Already in the library; the hash is of the existing image"
    [FOUND]="Hash or known source matched a stored image"
    [REMOVED]="Removed from the library (REMOVE)"
    [UNREACHABLE]="Could not connect to the website"
    [TIMEOUT]="Website did not respond in time"
    [NOTFOUND]="Website available, but the URL was not found"
    [RATELIMIT]="Website refused: too many requests"
    [HTTPERROR]="Other HTTP error"
    [NOTIMAGE]="Not an image, eg a login or error page"
    [BADIMAGE]="Image damaged, or could not be fingerprinted"
    [UNSUPPORTED]="Unsupported image format or URL type"
    [TORFAIL]="Failed through Tor"
    [NOFILE]="Local file does not exist"
    [UNREADABLE]="Local file can't be read"
    [NOHASH]="No image with this hash in the library"
    [NOTSTORED]="Not a stored image; REMOVE and UNTAG never download"
    [STOREFAIL]="Could not write to the library"
    [SHRINKFAIL]="Shrunk copy failed its check; retry with another SHRINK"
)

## Separates fields in _silLogRows. Not a tab: read merges consecutive
## whitespace separators, losing empty fields such as a failure's hash
declare -g _silSep=$'\x1f'

## State for the manifest being logged
declare -g _silErrLog="" _silMdLog="" _silLogName=""
declare -gA _silErrWritten=()
declare -ga _silLogRows=()

#######################################
# A parameter's current value, written so it reads back the same from a
# manifest (eg sizes in bytes as '512000b', percents as '25%').
# Arguments:
#   $1 - Canonical parameter name
# Outputs:
#   Value to STDOUT; nothing if the parameter is unset
#######################################
function paramFileValue {
    local var="SIL_$1"
    [[ -n "${!var:-}" ]] || return 0
    case "${_silParamType[$1]}" in
        size) [[ "${!var}" == 0 ]] && echo 0 || echo "${!var}b" ;;
        percent) echo "${!var}%" ;;
        flag) [[ "${!var}" == 1 ]] && echo on || echo off ;;
        *) printf '%s\n' "${!var}" ;;
    esac
}

#######################################
# Start the logs for a manifest, overwriting any from an earlier run.
# The error log is written as failures happen, so it survives an
# interrupted run.
# Globals:
#   Sets _silErrLog, _silMdLog, _silLogName, _silErrWritten, _silLogRows
# Arguments:
#   $1 - Manifest path
# Returns:
#   0 on success, 1 if the logs can't be written (logging is then off)
#######################################
function logStart {
    _silLogName="$(basename -- "$1")"
    _silErrLog="$1.err"
    _silMdLog="$1.md"
    _silErrWritten=()
    _silLogRows=()
    if ! cat > "$_silErrLog" 2> /dev/null << EOF
# Failed URIs from $_silLogName, written by sil on $(date '+%Y-%m-%d %H:%M')
# Each failure has a comment giving its reason. Settings in effect are
# written before the failures they applied to. To retry, review and edit,
# then rename to a .txt file in this folder and run it, eg:
#   mv '$_silLogName.err' retry.txt && sil retry.txt

EOF
    then
        msgWarn "[!] Can't write logs beside the manifest: $_silErrLog"
        _silErrLog=""
        _silMdLog=""
        return 1
    fi
}

#######################################
# Record one URI's outcome in the logs. Failures are written to the
# error log at once, preceded by any settings that changed since the
# last failure written.
# Globals:
#   _silLastOutcome, _silLastDetail, _silLastHash, _silParamType,
#   _silParamScope; updates _silErrWritten, _silLogRows
# Arguments:
#   $1 - The URI, as written in the manifest
#######################################
function logOutcome {
    [[ -n "$_silErrLog" ]] || return 0
    local uri="$1" canon value comment
    _silLogRows+=("$_silLastOutcome$_silSep${_silLastHash:0:12}$_silSep$uri")
    isSuccessTag "$_silLastOutcome" && return 0

    {
        for canon in $(printf '%s\n' "${!_silParamType[@]}" | sort); do
            ## One-time actions (eg LINK) are not settings to retry with
            [[ "${_silParamScope[$canon]:-}" == action ]] && continue
            value="$(paramFileValue "$canon")"
            [[ -n "$value" && "${_silErrWritten[$canon]:-}" != "$value" ]] || continue
            printf '%s=%s\n' "$canon" "$value"
            _silErrWritten[$canon]="$value"
        done
        comment="# $_silLastOutcome: ${_silLastDetail//$'\n'/ }"
        printf '%s\n%s\n\n' "${comment:0:80}" "$uri"
    } >> "$_silErrLog"
}

#######################################
# Escape text for a markdown table cell.
# Arguments:
#   $1 - Text
# Outputs:
#   Escaped text to STDOUT
#######################################
function mdCell {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//|/\\|}"
}

#######################################
# Write a legend of the outcome tags used in a set of rows, in order of
# first appearance.
# Arguments:
#   $1 - 'success' or 'failure': which tags to include
#   $@ - Rows, as from _silLogRows
# Outputs:
#   Markdown bullets to STDOUT
#######################################
function logLegend {
    local which="$1" row tag
    local -A seen=()
    shift
    for row in "$@"; do
        tag="${row%%"$_silSep"*}"
        [[ -n "${seen[$tag]:-}" ]] && continue
        if isSuccessTag "$tag"; then
            [[ "$which" == success ]] || continue
        else
            [[ "$which" == failure ]] || continue
        fi
        seen[$tag]=1
        printf -- '- **%s** - %s\n' "$tag" "${_silOutcomeMeaning[$tag]:-}"
    done
}

#######################################
# Finish the logs: write the markdown report, and report both paths.
# Globals:
#   _silMdLog, _silErrLog, _silLogName, _silLogRows
# Outputs:
#   The report file; log paths to STDERR
#######################################
function logFinish {
    [[ -n "$_silMdLog" ]] || return 0
    local row tag hash uri nFailed=0
    for row in "${_silLogRows[@]}"; do
        isSuccessTag "${row%%"$_silSep"*}" || nFailed=$(( nFailed + 1 ))
    done

    {
        printf '# Load report for %s\n\n' "$_silLogName"
        # shellcheck disable=SC2016  # Backticks are markdown, not expansion
        printf 'Run %s into `%s`\n\n' "$(date '+%Y-%m-%d %H:%M')" "$SIL_LIBRARY"
        if (( ${#_silLogRows[@]} > nFailed )); then
            logLegend success "${_silLogRows[@]}"
            printf '\n| Status | Hash | URI |\n| --- | --- | --- |\n'
            for row in "${_silLogRows[@]}"; do
                IFS="$_silSep" read -r tag hash uri <<< "$row"
                isSuccessTag "$tag" || continue
                printf '| %s | %s | %s |\n' "$tag" "$hash" "$(mdCell "$uri")"
            done
        else
            printf 'No images were added.\n'
        fi
        if (( nFailed )); then
            printf '\n# Failed image download\n\n'
            logLegend failure "${_silLogRows[@]}"
            printf '\n| Reason | URI |\n| --- | --- |\n'
            for row in "${_silLogRows[@]}"; do
                IFS="$_silSep" read -r tag hash uri <<< "$row"
                isSuccessTag "$tag" && continue
                printf '| %s | %s |\n' "$tag" "$(mdCell "$uri")"
            done
        fi
    } > "$_silMdLog"

    msgInfo "Report: $_silMdLog"
    if (( nFailed )); then
        msgInfo "Failures, ready to retry: $_silErrLog"
    else
        printf '# No failures\n' >> "$_silErrLog"
    fi
}
