## Utility function library

## Presuming this file is in the same folder as the main script, it
## can be reliably invoke from within the main script with:

# my_dir="$(dirname "$0")"
# source "$my_dir/utils.sh"

## Copyright (C) 2017,2026 Charles A. Tilford
##   Where I have used (or been inspired by) public code it will be noted
##   This file intially cloned from another of my repos:
##     https://github.com/VCF/installers/blob/master/games/launchers/_util_functions.sh

# Using dirname for calling directory: https://stackoverflow.com/a/192305
# Sourcing script with '.' :
#   http://www.unix.com/302168850-post2.html?s=34e24e03a7ea3080fed2982f1a0f038d

function srcLib {
    ## Just a simple function to pull in another bash library
    ## The function will also track if a library was already loaded.
    libFile="$1"
    if [[ -z "$libFile" ]]; then
        msgError "Function libFile needs to be provided with a filename
The file is expected to be in src, and should not include '.sh'"
    fi
    libPath="$myDir/src/$1.sh"
    if [[ -s "$libPath" ]]; then
        ## There appears to be a bash file here!
        ## Have we loaded it already?
        ##    variable indirection: https://unix.stackexchange.com/a/251896
        chkFlag="sil_loaded_$1"
        if [[ -z "${!chkFlag}" ]]; then
            # shellcheck source=/dev/null
            source "$libPath"
            printf -v "$chkFlag" '%s' "Loaded"
        fi
        # msgDebug "Loaded $libPath"
    else
        msgError "Could not find library to load: $1
  Path: $libPath"
    fi
}

srcLib "colors"

function ansiStart {
    ## Starting ANSI codes
    ## $1 - additional codes to add, presumably colors
    echo -e "\033[1;${1}m"
}

function ansiEnd {
    ## Closing ANSI codes - static string
    echo -e "\033[0m"
}

#######################################
# Print a colorized message to STDERR. Base for the msg* functions.
# Arguments:
#   $1 - ANSI color code(s), eg "$FgBlue" or "$BgYellow;$FgRed".
#        Defaults to green
#   $2 - The text to print
# Outputs:
#   Message to STDERR
#######################################
function msg {
    local col="${1:-$FgGreen}"
    >&2 echo -e "$(ansiStart "$col")${2}$(ansiEnd)"
}

#######################################
# Informational message for the user (UI-02: blue).
# Arguments:
#   $1 - The text to print
# Outputs:
#   Message to STDERR
#######################################
function msgInfo {
    msg "$FgBlue" "$1"
}

#######################################
# Warning; a problem, but execution continues (UI-02: red).
# Arguments:
#   $1 - The text to print
# Outputs:
#   Message to STDERR
#######################################
function msgWarn {
    msg "$FgRed" "$1"
}

#######################################
# Fatal error; halts execution (UI-02: red on yellow).
# Arguments:
#   $1 - The text to print
# Outputs:
#   Message to STDERR
# Returns:
#   Does not return; exits with status 1
#######################################
function msgError {
    msg "$BgYellow;$FgRed" "$1"
    exit 1
}

#######################################
# Developer debugging message.
# Arguments:
#   $1 - The text to print
# Outputs:
#   Message to STDERR, prefixed with [DEBUG]
#######################################
function msgDebug {
    msg "$BgCyan;$FgMagenta" "[DEBUG] $1"
}

function set_title {
    ## Change title of terminal window header
    ##   https://unix.stackexchange.com/a/11230
    ##  $1 - The title to show
    echo -ne "\033]0;$1\007";
}

#######################################
# Replace a leading path prefix, by default $HOME with '~', for
# friendlier display.
# Arguments:
#   $1 - The text to modify
#   $2 - Prefix to replace (default: $HOME)
#   $3 - Replacement (default: ~)
# Outputs:
#   Modified text to STDOUT
#######################################
function setTilda {
    local txt="$1"
    local in="${2:-$HOME}"
    local out="${3:-~}"
    ## Quoting $out stops bash 5.2+ treating '&' in it as the match
    echo "${txt/#"$in"/"$out"}"
}

#######################################
# Relative path from one directory to another, eg for symlink targets.
# Purely lexical: neither path needs to exist and symlinks are not
# resolved.
# Arguments:
#   $1 - Directory to start from
#   $2 - Path to reach
# Outputs:
#   Relative path to STDOUT ('.' if they are the same)
#######################################
function relativePath {
    realpath -ms --relative-to="$1" "$2"
}

#######################################
# Halt with install instructions if a command is not available (UI-01).
# Arguments:
#   $1 - Command name
#   $2 - Debian/Ubuntu package that provides it
#   $3 - What SIL needs it for
# Returns:
#   0 if available; otherwise halts (msgError)
#######################################
function requireTool {
    command -v "$1" > /dev/null && return 0
    msgError "[!] Required tool '$1' is not installed
    It is needed to: $3
    Install it with:
      sudo apt install $2"
}

#######################################
# Format a byte count for people, eg 512000 -> '500 KB'.
# Arguments:
#   $1 - Byte count
# Outputs:
#   Formatted size to STDOUT
#######################################
function humanSize {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB", u, " ")
        for (i = 1; b >= 1024 && i < 4; i++) b /= 1024
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
    }'
}
