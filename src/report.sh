## Manifest logs: <manifest>.err and <manifest>.md - see REQ-08

## Meaning of each outcome tag, for the report legends (REQ-08)
declare -gA _silOutcomeMeaning=(
    [ADDED]="Recovered and added to the library"
    [SHRINK]="Recovered, shrunk and added"
    [UPGRADED]="Replaced a smaller copy in the library, keeping its tags (KEEPLARGER)"
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

## Failures, for regrouping the error log by reason in logFinish: one
## "<tag><sep><uri>" row per failure, with the settings in effect for it
## (CANON=value lines, as from logSettings) at the same index
declare -ga _silErrRows=() _silErrSettings=()

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
# Write the error log's header.
# Globals:
#   _silLogName
# Outputs:
#   Header comment lines to STDOUT
#######################################
function logErrHeader {
    cat << EOF
# Failed URIs from $_silLogName, written by sil on $(date '+%Y-%m-%d %H:%M')
# Failures are grouped under a comment giving their reason. Settings in
# effect are written before the failures they applied to. To retry,
# review and edit, then rename to a .txt file in this folder and run it:
#   mv '$_silLogName.err' retry.txt && sil retry.txt

EOF
}

#######################################
# Start the logs for a manifest, overwriting any from an earlier run.
# The error log is written as failures happen, so it survives an
# interrupted run; logFinish then rewrites it grouped by reason.
# Globals:
#   Sets _silErrLog, _silMdLog, _silLogName, _silErrWritten, _silLogRows,
#   _silErrRows, _silErrSettings
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
    _silErrRows=()
    _silErrSettings=()
    if ! logErrHeader > "$_silErrLog" 2> /dev/null; then
        msgWarn "[!] Can't write logs beside the manifest: $_silErrLog"
        _silErrLog=""
        _silMdLog=""
        return 1
    fi
}

#######################################
# The settings in effect that a retry needs: every set parameter except
# one-time actions (eg LINK). LIBRARY comes first, as a manifest needs it
# before any other setting or URI; it is already an absolute path, so a
# moved retry file still finds the library.
# Globals:
#   _silParamType, _silParamScope, SIL_<NAME>
# Outputs:
#   CANON=value lines to STDOUT, LIBRARY then the rest sorted by name
#######################################
function logSettings {
    local canon value
    [[ -n "${SIL_LIBRARY:-}" ]] && printf 'LIBRARY=%s\n' "$SIL_LIBRARY"
    for canon in $(printf '%s\n' "${!_silParamType[@]}" | sort); do
        [[ "${_silParamScope[$canon]:-}" == action || "$canon" == LIBRARY ]] && continue
        value="$(paramFileValue "$canon")"
        [[ -n "$value" ]] && printf '%s=%s\n' "$canon" "$value"
    done
    return 0
}

#######################################
# Record one URI's outcome in the logs. Failures are appended to the
# error log at once, preceded by any settings that changed since the
# last failure written, and kept for logFinish to regroup.
# Globals:
#   _silLastOutcome, _silLastDetail, _silLastHash; updates
#   _silErrWritten, _silLogRows, _silErrRows, _silErrSettings
# Arguments:
#   $1 - The URI, as written in the manifest
#######################################
function logOutcome {
    [[ -n "$_silErrLog" ]] || return 0
    local uri="$1" settings comment
    _silLogRows+=("$_silLastOutcome$_silSep${_silLastHash:0:12}$_silSep$uri")
    isSuccessTag "$_silLastOutcome" && return 0

    settings="$(logSettings)"
    _silErrRows+=("$_silLastOutcome$_silSep$uri")
    _silErrSettings+=("$settings")
    {
        logSettingsChanged "$settings"
        comment="# $_silLastOutcome: ${_silLastDetail//$'\n'/ }"
        printf '%s\n%s\n\n' "${comment:0:80}" "$uri"
    } >> "$_silErrLog"
}

#######################################
# Write the settings of a failure that differ from those already written
# to the error log, and note them as written.
# Globals:
#   Updates _silErrWritten
# Arguments:
#   $1 - Settings, as from logSettings
# Outputs:
#   CANON=value lines to STDOUT
#######################################
function logSettingsChanged {
    local line
    while IFS= read -r line; do
        [[ -n "$line" && "${_silErrWritten[${line%%=*}]:-}" != "${line#*=}" ]] || continue
        printf '%s\n' "$line"
        _silErrWritten[${line%%=*}]="${line#*=}"
    done <<< "$1"
}

#######################################
# Rewrite the error log with failures grouped under one comment per
# reason. Settings of the first failure come first, with TAG and the
# other image settings in a block of their own; after that, settings are
# written only where they change before a URI.
# TAG and UNTAG can't be cleared in a manifest, so a failure from before
# one was first set can't follow a failure that had it. Failures are
# therefore grouped in runs, starting a new run wherever a setting is
# first set; reasons can appear once in each run.
# Globals:
#   _silErrLog, _silErrRows, _silErrSettings, _silParamScope,
#   _silOutcomeMeaning; resets _silErrWritten
# Outputs:
#   The error log file
#######################################
function logErrGrouped {
    local i j start end tag uri line comment
    local -a image=() other=() tags=()
    local -A seen=()
    _silErrWritten=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "${_silParamScope[${line%%=*}]:-}" != image ]]; then
            other+=("$line")
        elif [[ "$line" == TAG=* ]]; then
            image=("$line" "${image[@]}")
        else
            image+=("$line")
        fi
    done <<< "${_silErrSettings[0]}"

    {
        logErrHeader
        for line in "${other[@]}" "" "${image[@]}"; do
            [[ -n "$line" ]] && _silErrWritten[${line%%=*}]="${line#*=}"
            printf '%s\n' "$line"
        done
        (( ${#image[@]} )) && printf '\n'

        start=0
        while (( start < ${#_silErrRows[@]} )); do
            ## End the run where a failure has a setting the one before lacked
            end=$(( start + 1 ))
            while (( end < ${#_silErrRows[@]} )); do
                while IFS= read -r line; do
                    [[ -n "$line" ]] || continue
                    grep -q "^${line%%=*}=" <<< "${_silErrSettings[end - 1]}" || break 2
                done <<< "${_silErrSettings[end]}"
                end=$(( end + 1 ))
            done

            tags=()
            seen=()
            for (( i = start; i < end; i++ )); do
                tag="${_silErrRows[i]%%"$_silSep"*}"
                [[ -n "${seen[$tag]:-}" ]] || tags+=("$tag")
                seen[$tag]=1
            done
            for tag in "${tags[@]}"; do
                comment="# $tag: ${_silOutcomeMeaning[$tag]:-}"
                printf '%s\n' "${comment:0:80}"
                for (( j = start; j < end; j++ )); do
                    [[ "${_silErrRows[j]%%"$_silSep"*}" == "$tag" ]] || continue
                    uri="${_silErrRows[j]#*"$_silSep"}"
                    logSettingsChanged "${_silErrSettings[j]}"
                    printf '%s\n' "$uri"
                done
                printf '\n'
            done
            start=$end
        done
    } > "$_silErrLog"
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
# Finish the logs: write the markdown report, regroup the error log by
# reason, and report both paths.
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
        logErrGrouped
        msgInfo "Failures, ready to retry: $_silErrLog"
    else
        printf '# No failures\n' >> "$_silErrLog"
    fi
}
