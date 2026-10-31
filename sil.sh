#!/usr/bin/env bash

## This script's real folder, used to source in other code. readlink -f
## resolves symlinks, so sil can be linked into eg ~/bin or ~/.local/bin
myDir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

## Load in basic functions
# shellcheck source=src/utils.sh
source "$myDir/src/utils.sh"

if [[ $# -eq 0 ]]; then
    ## No arguments passed, show help
    srcLib "help"
    showHelp
    exit 0
fi

srcLib "params"
srcLib "library"
srcLib "manifest"

## REQ-02 precedence: defaults < ~/.sil.conf < library sil.conf < command line
loadParams "$@"
resolveLibrary
loadLibraryParams

msgInfo "Library: $SIL_LIBRARY"
showParams

if (( ${#_silArgs[@]} == 0 )); then
    msgInfo "No images or manifests given, nothing more to do"
    exit 0
fi

## Exit status is 1 if any image or manifest failed, for use in scripts
status=0
for arg in "${_silArgs[@]}"; do
    if [[ -f "$arg" && "${arg,,}" == *.txt ]]; then
        ## REQ-06: manifests are text files with a .txt suffix
        parseManifest "$arg" || status=1
    else
        processURI "$arg" || status=1
    fi
done
exit "$status"
