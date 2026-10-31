## Parameter registry and parsing - see docs/parameters.md (UI-03, REQ-02)
##
## Parameters are stored as global variables SIL_<NAME>. Internal state
## uses the _sil prefix so it can never collide with a parameter name.
##
## NOTE: srcLib sources this file from inside a function, so every
## declare here MUST use -g or it will be local to srcLib.

## Canonical parameter names and their type. Types other than 'value'
## are validated and normalized by normalizeParamValue:
##   flag    - 1 or 0
##   size    - bytes, from eg '500kb', '2mb', '1.5m'
##   percent - integer 0-100, from eg '25' or '25%'
##   number  - positive decimal, eg '2' or '1.5'
declare -gA _silParamType=(
    [LIBRARY]=value
    [TAG]=value
    [LINK]=value
    [SHRINK]=size
    [SHRINKTRIGGER]=number
    [SHRINKMINSAVE]=percent
    [FLATTEN]=flag
    [THRESHOLD]=percent
    [CHECK]=flag
    [REBUILD]=flag
    [TOR]=flag
)

## Alias -> canonical name
declare -gA _silParamAlias=(
    [TAGS]=TAG
    [USETOR]=TOR
)

## Values applied by resetParams before any source is read
declare -gA _silParamDefault=(
    [SHRINK]=0
    [SHRINKTRIGGER]=2
    [SHRINKMINSAVE]=25
    [FLATTEN]=0
    [THRESHOLD]=90
    [TOR]=0
)

## Parameters restricted in configuration files. Unlisted parameters
## are library-wide settings, allowed anywhere.
##   image  - applied to individual images; never in a conf file
##   action - a one-time operation; never in a conf file
##   global - allowed in ~/.sil.conf, but not a library's own sil.conf
declare -gA _silParamScope=(
    [TAG]=image
    [LINK]=action
    [CHECK]=action
    [REBUILD]=action
    [LIBRARY]=global
)

## Populated by parseCliParams
declare -ga _silCliParams=()
declare -ga _silArgs=()

#######################################
# Remove leading and trailing whitespace.
# Arguments:
#   $1 - Text to trim
# Outputs:
#   Trimmed text to STDOUT (no trailing newline)
#######################################
function trim {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

#######################################
# Remove one pair of matching surrounding quotes (single or double).
# Shells strip quotes on the command line, but conf and manifest files
# are read literally, so TAG='Meme/Politics' needs this.
# Arguments:
#   $1 - Text to unquote
# Outputs:
#   Unquoted text to STDOUT (no trailing newline)
#######################################
function unquote {
    local s="$1"
    if [[ ${#s} -ge 2 && ( "$s" == \'*\' || "$s" == \"*\" ) ]]; then
        s="${s:1:${#s}-2}"
    fi
    printf '%s' "$s"
}

#######################################
# Convert a human file size to bytes. Units are case-insensitive and
# 1024-based; a bare number is kilobytes.
#   500 = 500k = 500kb = 512000, 2mb = 2097152, 1.5m, 10b, 1g
# Arguments:
#   $1 - Size text
# Outputs:
#   Integer byte count to STDOUT
# Returns:
#   0 if parsed, 1 if not a valid size
#######################################
function parseSize {
    local txt="${1,,}"
    [[ "$txt" =~ ^([0-9]+)(\.([0-9]+))?[[:space:]]*([kmg]?)(b?)$ ]] || return 1
    local whole="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[3]}"
    local unit="${BASH_REMATCH[4]}" bytesOnly="${BASH_REMATCH[5]}"
    local mult=1024
    case "$unit" in
        m) mult=$(( 1024 ** 2 )) ;;
        g) mult=$(( 1024 ** 3 )) ;;
        '') [[ -n "$bytesOnly" ]] && mult=1 ;;
    esac
    local bytes=$(( 10#$whole * mult ))
    [[ -n "$frac" ]] && bytes=$(( bytes + 10#$frac * mult / 10 ** ${#frac} ))
    printf '%s\n' "$bytes"
}

#######################################
# Validate and normalize a parameter value according to its type.
# Arguments:
#   $1 - Type, from _silParamType
#   $2 - Value (already trimmed and unquoted)
# Outputs:
#   Normalized value to STDOUT
# Returns:
#   0 if valid, 1 otherwise
#######################################
function normalizeParamValue {
    local type="$1" value="$2"
    case "$type" in
        size)
            parseSize "$value"
            ;;
        percent)
            [[ "$value" =~ ^([0-9]{1,3})%?$ ]] || return 1
            (( 10#${BASH_REMATCH[1]} <= 100 )) || return 1
            printf '%s\n' "$(( 10#${BASH_REMATCH[1]} ))"
            ;;
        number)
            [[ "$value" =~ ^[0-9]*\.?[0-9]+$ && "$value" =~ [1-9] ]] || return 1
            printf '%s\n' "$value"
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

#######################################
# Resolve a parameter name or alias (any case) to its canonical name.
# Globals:
#   _silParamType, _silParamAlias
# Arguments:
#   $1 - Parameter name or alias
# Outputs:
#   Canonical uppercase name to STDOUT
# Returns:
#   0 if recognized, 1 otherwise
#######################################
function paramCanonical {
    local name="${1^^}"
    [[ -n "$name" ]] || return 1
    [[ -n "${_silParamAlias[$name]:-}" ]] && name="${_silParamAlias[$name]}"
    [[ -n "${_silParamType[$name]:-}" ]] || return 1
    printf '%s\n' "$name"
}

#######################################
# Test whether a token is a recognized parameter, either NAME or
# NAME=VALUE.
# Arguments:
#   $1 - Token to test
# Returns:
#   0 if the token is a known parameter, 1 otherwise
#######################################
function isParamToken {
    [[ "$1" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(=|$) ]] \
        || return 1
    paramCanonical "${BASH_REMATCH[1]}" > /dev/null
}

#######################################
# Test whether a token is shaped like NAME=VALUE, regardless of whether
# NAME is recognized. Used to catch misspelled parameters.
# Arguments:
#   $1 - Token to test
# Returns:
#   0 if parameter-shaped, 1 otherwise
#######################################
function looksLikeParam {
    [[ "$1" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]
}

#######################################
# Parse a NAME or NAME=VALUE token and set the matching SIL_<NAME>
# variable. Flags become 1, or 0 if given 0/no/false/off (any case).
# Value parameters are trimmed and unquoted.
# Globals:
#   _silParamType; sets SIL_<NAME>
# Arguments:
#   $1 - Token, eg 'tag = Meme' or 'TOR'
#   $2 - Optional source description for messages
# Returns:
#   0 on success, 1 if the parameter is unrecognized.
#   Halts (msgError) if a value is missing or invalid for its type.
#######################################
function setParamToken {
    local token="$1"
    local src="${2:-command line}"
    local name value canon
    local hasValue=0

    if [[ "$token" == *=* ]]; then
        name="${token%%=*}"
        value="${token#*=}"
        hasValue=1
    else
        name="$token"
    fi
    name="$(trim "$name")"

    if ! canon="$(paramCanonical "$name")"; then
        msgWarn "[!] Unrecognized parameter '$name' ($src) - ignored"
        return 1
    fi

    value="$(unquote "$(trim "$value")")"
    local type="${_silParamType[$canon]}"
    if [[ "$type" == flag ]]; then
        if (( hasValue )) && [[ "${value,,}" =~ ^(0|no|false|off)$ ]]; then
            value=0
        else
            value=1
        fi
    elif (( ! hasValue )) || [[ -z "$value" ]]; then
        msgError "[!] Parameter $canon requires a value, eg: $canon=something
    Found in: $src"
    elif ! value="$(normalizeParamValue "$type" "$value")"; then
        local -A example=(
            [size]="500kb, 2mb, 1.5m"
            [percent]="25 or 25%"
            [number]="2 or 1.5"
        )
        msgError "[!] Invalid $type for $canon: '$value'
    Expected eg: ${example[$type]}
    Found in: $src"
    fi

    printf -v "SIL_$canon" '%s' "$value"
}

#######################################
# Test whether a flag parameter is on.
# Arguments:
#   $1 - Parameter name or alias
# Returns:
#   0 if SIL_<NAME> is 1, 1 otherwise
#######################################
function flagIsSet {
    local canon
    canon="$(paramCanonical "$1")" || return 1
    local var="SIL_$canon"
    [[ "${!var:-0}" == 1 ]]
}

#######################################
# Clear all SIL_<NAME> variables, then apply defaults. Prevents values
# leaking in from the calling environment.
# Globals:
#   _silParamType, _silParamDefault; sets/unsets SIL_<NAME>
#######################################
function resetParams {
    local canon
    for canon in "${!_silParamType[@]}"; do
        unset "SIL_$canon"
    done
    for canon in "${!_silParamDefault[@]}"; do
        printf -v "SIL_$canon" '%s' "${_silParamDefault[$canon]}"
    done
}

#######################################
# Split command line arguments into parameter tokens and remaining
# arguments (URIs / manifests). Parameters must precede the first URI.
# Nothing is applied here; see loadParams for precedence handling.
# Globals:
#   Sets _silCliParams, _silArgs
# Arguments:
#   $@ - Command line arguments
# Returns:
#   Halts (msgError) on an unrecognized NAME=VALUE token, or on a parameter
#   following a URI.
#######################################
function parseCliParams {
    _silCliParams=()
    _silArgs=()
    local arg
    for arg in "$@"; do
        if isParamToken "$arg"; then
            if (( ${#_silArgs[@]} )); then
                msgError "[!] Parameter '$arg' follows a URI
    Parameters must come before any URIs or manifests, eg:
      sil TAG=Meme https://example.com/funny.jpg"
            fi
            _silCliParams+=("$arg")
        elif looksLikeParam "$arg" && [[ ! -e "$arg" ]]; then
            msgError "[!] Unrecognized parameter '${arg%%=*}'
    See docs/parameters.md for recognized parameters.
    If this is a file name, prefix it with ./"
        else
            _silArgs+=("$arg")
        fi
    done
}

#######################################
# Test whether a parameter may be set in a given kind of conf file,
# warning the user if not.
# Globals:
#   _silParamScope
# Arguments:
#   $1 - Canonical parameter name
#   $2 - Conf kind: 'global' (~/.sil.conf) or 'library' (sil.conf)
#   $3 - Source description for messages
# Returns:
#   0 if allowed, 1 if not (after warning)
#######################################
function paramAllowedInConf {
    local canon="$1" kind="$2" src="$3"
    local why
    case "${_silParamScope[$canon]:-}" in
        image)
            why="it applies to individual images, not a whole library" ;;
        action)
            why="it is a one-time action, not a setting" ;;
        global)
            [[ "$kind" == global ]] && return 0
            why="a library's own sil.conf is only read once the library is known" ;;
        *)
            return 0 ;;
    esac
    msgWarn "[!] $canon can't be set in a configuration file - ignored
    Reason: $why
    Set it on the command line or in a manifest instead
    Found in: $src"
    return 1
}

#######################################
# Read parameter settings from a configuration file. Blank lines and
# lines starting with # are skipped; other lines must be parameters
# allowed in that kind of file (see _silParamScope).
# Arguments:
#   $1 - Path to the file
#   $2 - Conf kind: 'global' (~/.sil.conf) or 'library' (default)
# Returns:
#   0 on success (including a missing file), 1 if any line was ignored
#######################################
function parseParamFile {
    local path="$1"
    local kind="${2:-library}"
    local line lineNum=0 rv=0 canon
    [[ -f "$path" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNum=$(( lineNum + 1 ))
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if isParamToken "$line"; then
            canon="$(paramCanonical "$(trim "${line%%=*}")")"
            if paramAllowedInConf "$canon" "$kind" "$path line $lineNum"; then
                setParamToken "$line" "$path line $lineNum"
            else
                rv=1
            fi
        else
            msgWarn "[!] Not a parameter setting, ignored: '$line'
    Found in: $path line $lineNum"
            rv=1
        fi
    done < "$path"
    return "$rv"
}

#######################################
# Test whether a parameter was given on the command line.
# Globals:
#   _silCliParams
# Arguments:
#   $1 - Parameter name or alias
# Returns:
#   0 if given, 1 otherwise
#######################################
function cliHasParam {
    local want token
    want="$(paramCanonical "$1")" || return 1
    for token in "${_silCliParams[@]}"; do
        [[ "$(paramCanonical "$(trim "${token%%=*}")")" == "$want" ]] && return 0
    done
    return 1
}

#######################################
# Apply command line parameters, which outrank conf files.
# Globals:
#   _silCliParams; sets SIL_<NAME>
#######################################
function applyCliParams {
    local token
    for token in "${_silCliParams[@]}"; do
        setParamToken "$token"
    done
}

#######################################
# First stage of REQ-02 precedence: defaults < ~/.sil.conf < command
# line. The library is not known yet; once it is (resolveLibrary), call
# loadLibraryParams. Manifest parameters are applied during manifest
# parsing.
# Globals:
#   HOME; sets SIL_<NAME>, _silCliParams, _silArgs
# Arguments:
#   $@ - Command line arguments
#######################################
function loadParams {
    resetParams
    parseCliParams "$@"
    ## Problems in conf files are reported as warnings, not fatal
    parseParamFile "$HOME/.sil.conf" global || :
    applyCliParams
}

#######################################
# Second stage of REQ-02 precedence: apply the library's sil.conf, then
# the command line again so it still wins. SIL_LIBRARY keeps the
# absolute path from resolveLibrary, rather than the command line text.
# Globals:
#   SIL_LIBRARY; sets SIL_<NAME>
#######################################
function loadLibraryParams {
    local lib="$SIL_LIBRARY"
    parseParamFile "$lib/sil.conf" library || :
    applyCliParams
    SIL_LIBRARY="$lib"
}

#######################################
# Report current parameter values to the user (UI-01).
# Globals:
#   _silParamType, SIL_<NAME>
# Outputs:
#   One msgInfo line per set parameter, to STDERR
#######################################
function showParams {
    local canon var
    for canon in $(printf '%s\n' "${!_silParamType[@]}" | sort); do
        var="SIL_$canon"
        [[ -n "${!var+x}" ]] || continue
        if [[ "${_silParamType[$canon]}" == size && "${!var}" != 0 ]]; then
            msgInfo "  $canon = ${!var} ($(humanSize "${!var}"))"
        else
            msgInfo "  $canon = ${!var}"
        fi
    done
}
