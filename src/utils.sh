## Utility function library

## Presuming this file is in the same folder as the main script, it
## can be reliably invoke from within the main script with:

# my_dir="$(dirname "$0")"
# source "$my_dir/utils.sh"

## Copyright (C) 2017,2026 Charles A. Tilford
##   Where I have used (or been inspired by) public code it will be noted
##   This file intially cloned from another of my repos:
##     https://github.com/VCF/installers/blob/master/games/launchers/_util_functions.sh

LICENSE_GPL3="

    This program is free software: you can redistribute it and/or
    modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see http://www.gnu.org/licenses/

"

# Using dirname for calling directory: https://stackoverflow.com/a/192305
# Sourcing script with '.' :
#   http://www.unix.com/302168850-post2.html?s=34e24e03a7ea3080fed2982f1a0f038d

function srcLib {
    ## Just a simple function to pull in another bash library
    ## The function will also track if a library was already loaded.
    libFile="$1"
    if [[ -z "$libFile" ]]; then
        die "Function libFile needs to be provided with a filename
The file is expected to be in src, and should not include '.sh'"
    fi
    libPath="$myDir/src/$1.sh"
    if [[ -s "$libPath" ]]; then
        ## There appears to be a bash file here!
        ## Have we loaded it already?
        ##    variable indirection: https://unix.stackexchange.com/a/251896
        chkFlag="sil_loaded_$1"
        if [[ -z "${!chkFlag}" ]]; then
            source "$libPath"
            ## Use namerefs to set the flag (Google AI suggestion)
            declare -n ref="$chkFlag"
            ref="Loaded"
        fi
        # dbg "Loaded $libPath"
    else
        die "Could not find library to load: $1
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

function msg {
    ## Colorized terminal message.
    COL=$1 # The ANSI color code(s)
    MSG=$2 # The text to print
    [[ -z "$COL" ]] && col="32"
    >&2 echo -e "$(ansiStart "$COL")${MSG}$(ansiEnd)";
}

function info {
    ## Red on yellow, execution continues
    ##  $1 - The text to print
    msg "$FgBlue" "$1"
}

function err {
    ## Red on yellow, execution continues
    ##  $1 - The text to print
    msg "$BgYellow;$FgRed" "$1"
}

function dbg {
    ## Debugging message, 
    ##  $1 - The text to print
    msg "$BgCyan;$FgMagenta" "[DEBUG] $1"
}

function die {
    ## Yellow on red, halts
    ##  $1 - The text to print
    msg "$BgRed;$FgYellow" "$1"
    exit
}

function set_title {
    ## Change title of terminal window header
    ##   https://unix.stackexchange.com/a/11230
    ##  $1 - The title to show
    echo -ne "\033]0;$1\007";
}

function setTilda {
    ## Just swaps values, by default replaces $HOME with '~'
    txt=$1         # The text to modify
    in=${2:-$HOME} # The value to replace
    out=${3:-'~'}  # What it should be replaced with
    ## sed with slashes: https://unix.stackexchange.com/a/39802
    echo "$txt" | sed "s|$in|$out|"
}

function relativePath {
    ## Ok... this works great: https://unix.stackexchange.com/a/233882
    ## ... but Mint 13 Maya has only realpath version 1.16, which does
    ## not support the --relative-to parameter. So we're going to do
    ## this with regular expressions, since I don't need to "back up"
    ## (That is, one directory is a child of the other)
    BaseDir=$1 # The 'higher level' directory
    FullDir=$2 # The deeper directory (child of BaseDir)
    ## Make sure directories ends with a slash
    ##   Glob pattern matching: https://stackoverflow.com/a/44688520
    [[ ! "$BaseDir" == *,/$,* ]] && BaseDir="$BaseDir"/
    [[ ! "$FullDir" == *,/$,* ]] && FullDir="$FullDir"/
    ## With realpath: realpath --relative-to="$BaseDir" "$FullDir"
    rv=`echo "$FullDir" | sed "s|$BaseDir||"`
    [[ "$rv" == "" ]] && rv='.'
    echo "$rv"
}

function hasParam {
    ## Uppercasing variables: https://stackoverflow.com/a/19411918
    PARAM=${1^^} # The parameter settings that were provided
    VAL=${2^^}   # The value to check against
    [[ "$PARAM" == *"$VAL"* ]] && echo "$VAL"
}
