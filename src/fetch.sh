## Recovering images from URIs - see REQ-03 and REQ-04

## Generic UA matching Tor Browser's uniform one, so requests (Tor or not)
## don't carry a SIL-specific fingerprint. Update with Tor Browser ESR bumps
declare -g _silUserAgent="Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0"

## Set by fetchURI on failure: REQ-08 reason tag, and an explanation
declare -g _silFetchReason="" _silFetchDetail=""

#######################################
# Classify a URI (REQ-03).
# Arguments:
#   $1 - The URI
# Outputs:
#   'url', 'hash' or 'path' to STDOUT
#######################################
function uriKind {
    if [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
        echo url
    elif [[ "$1" =~ ^[0-9A-Fa-f]{40}$ && ! -e "$1" ]]; then
        echo hash
    else
        echo path
    fi
}

#######################################
# Record why a fetch failed, for the caller to report.
# Globals:
#   Sets _silFetchReason, _silFetchDetail
# Arguments:
#   $1 - REQ-08 reason tag
#   $2 - Explanation
# Returns:
#   1, so callers can 'return' it
#######################################
function fetchFailed {
    _silFetchReason="$1"
    _silFetchDetail="$2"
    return 1
}

#######################################
# Copy a local file to a destination.
# Arguments:
#   $1 - File path
#   $2 - Destination file
# Returns:
#   0 on success; 1 on failure (see fetchFailed)
#######################################
function fetchPath {
    [[ -e "$1" ]] || fetchFailed NOFILE "File not found" || return 1
    [[ -f "$1" && -r "$1" ]] || fetchFailed UNREADABLE "Not a readable file" || return 1
    cp -- "$1" "$2" 2> /dev/null || fetchFailed UNREADABLE "Could not copy the file" || return 1
}

#######################################
# Download a URL with curl, through Tor (torsocks) for .onion addresses
# or when TOR is set (REQ-04).
# Globals:
#   SIL_TOR, _silUserAgent
# Arguments:
#   $1 - URL
#   $2 - Destination file
# Returns:
#   0 on success; 1 on failure (see fetchFailed)
#######################################
function fetchURL {
    local url="$1" dest="$2"
    local host code rc errTxt
    local -a cmd=()

    [[ "${url,,}" =~ ^https?:// ]] \
        || fetchFailed UNSUPPORTED "Only http and https URLs are supported" || return 1
    requireTool curl curl "download images from URLs"

    host="${url#*://}"
    host="${host%%[/?#]*}"
    host="${host##*@}"
    host="${host%:*}"
    if [[ "${host,,}" == *.onion ]] || flagIsSet TOR; then
        requireTool torsocks torsocks "download through Tor (TOR, .onion addresses)"
        cmd=(torsocks)
    fi

    errTxt="$(silMktemp)" || fetchFailed STOREFAIL "No temp space" || return 1
    msgStatus "  Downloading from $host${cmd[*]:+ through Tor}"
    code="$("${cmd[@]}" curl --silent --show-error --location \
        --user-agent "$_silUserAgent" --connect-timeout 30 --max-time 300 \
        --output "$dest" --write-out '%{http_code}' -- "$url" 2> "$errTxt")"
    rc=$?
    local err
    err="$(head -c 200 "$errTxt")"
    rm -f -- "$errTxt"

    if (( rc != 0 )); then
        case "$rc" in
            28) fetchFailed TIMEOUT "No response in time" ;;
            *)
                if (( ${#cmd[@]} )); then
                    fetchFailed TORFAIL "Failed through Tor; is Tor running? (systemctl status tor) $err"
                else
                    fetchFailed UNREACHABLE "${err:-curl error $rc}"
                fi
                ;;
        esac
        return 1
    fi
    case "$code" in
        2??) return 0 ;;
        404|410) fetchFailed NOTFOUND "HTTP $code" ;;
        429) fetchFailed RATELIMIT "HTTP 429, too many requests" ;;
        *) fetchFailed HTTPERROR "HTTP $code" ;;
    esac
}

#######################################
# Recover a URL or local file into a new temporary file with no suffix,
# so its format is judged by content (REQ-04, REQ-05).
# Globals:
#   Sets _silFetchReason, _silFetchDetail on failure
# Arguments:
#   $1 - URL or local path
#   $2 - Name of the variable to receive the temporary file's path
# Returns:
#   0 on success; 1 on failure, with nothing left behind
#######################################
function fetchURI {
    local _uri="$1" _resultVar="$2" _tmp
    _silFetchReason=""
    _silFetchDetail=""
    _tmp="$(silMktemp)" || fetchFailed STOREFAIL "No temp space" || return 1
    if [[ "$(uriKind "$_uri")" == url ]]; then
        fetchURL "$_uri" "$_tmp"
    else
        fetchPath "$_uri" "$_tmp"
    fi || { rm -f -- "$_tmp"; return 1; }
    printf -v "$_resultVar" '%s' "$_tmp"
}
