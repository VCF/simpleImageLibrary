#!/usr/bin/env bash

## This script's source directory. Will be used to source in other code
myDir="$(dirname "$0")"

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
    info "[?] Unknown parameter '$1'
    Run this script with no arguments for full help"
fi


srcLib "help"
srcLib "help"
srcLib "help"
srcLib "help"

