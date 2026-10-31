#!/usr/bin/env bash

## This script's real folder, used to source in other code. readlink -f
## resolves symlinks, so sil can be linked into eg ~/bin or ~/.local/bin
myDir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

## Load in basic functions
source "$myDir/src/utils.sh"

if [[ -z "$1" ]]; then
    ## No arguments passed, show help
    srcLib "help"
    showHelp
elif [[ -f "$1" ]]; then
    ## The first argument is a file - this will be presumed to be a manifest
    srcLib "manifest"
    parseManifest "$1"
else
    ## Not really sure what's being asked here. Point user to help
    msgInfo "[?] Unknown parameter '$1'
    Run this script with no arguments for full help"
fi
