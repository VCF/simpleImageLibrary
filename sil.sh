#!/usr/bin/env bash

## This script's real folder, used to source in other code. readlink -f
## resolves symlinks, so sil can be linked into eg ~/bin or ~/.local/bin
myDir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

## Load in basic functions
# shellcheck source=src/utils.sh
source "$myDir/src/utils.sh"

## Help if there are no arguments, or if asked for anywhere among them. This
## comes first, so that eg 'sil LIBRARY=new --help' doesn't create a library.
## A file really named -h can be given as ./-h
wantHelp=0
(( $# == 0 )) && wantHelp=1
for arg in "$@"; do
    [[ "$arg" == -h || "$arg" == --help ]] && wantHelp=1
done
if (( wantHelp )); then
    srcLib "help"
    showHelp
    exit 0
fi

srcLib "params"
srcLib "library"
srcLib "manifest"
srcLib "maintain"

## REQ-02 precedence: defaults < ~/.sil.conf < library sil.conf < command
## line < manifest
loadParams "$@"

## With no library yet, manifests may name one (REQ-06); anything else
## needs one now
needLibrary=0
if flagIsSet CHECK || flagIsSet REBUILD || [[ -n "${SIL_LINK:-}${SIL_REMAP:-}" ]]; then
    needLibrary=1
fi
for arg in "${_silArgs[@]}"; do
    [[ -f "$arg" && "${arg,,}" == *.txt ]] || needLibrary=1
done
if lib="$(chooseLibrary)"; then
    useLibrary "$lib"
    loadLibraryParams
    msgInfo "Library: $SIL_LIBRARY"
elif (( needLibrary || ${#_silArgs[@]} == 0 )); then
    noLibraryError
else
    unset SIL_LIBRARY
    msgInfo "Library: to be set by the manifest"
fi
showParams

## One date for the whole run, even past midnight (TAG-02)
_silToday="$(todayDate)"
if (( ${#_silArgs[@]} )) && ! flagIsSet REMOVE && [[ -z "${SIL_UNTAG:-}" ]]; then
    msgInfo "New images will be tagged $_silDateTag/${_silToday:0:4}/$_silToday"
fi

## Exit status is 1 if anything failed, for use in scripts
status=0

## Act on any hand edits to the library's remapped tags (REMAP)
syncRemaps || status=1

## REQ-09 maintenance actions; rebuild first so a check sees the result
if flagIsSet REBUILD; then
    libraryRebuild || status=1
fi
if flagIsSet CHECK; then
    libraryCheck || status=1
fi
## REMAP first, so a LINK given with it follows the new remap
if [[ -n "${SIL_REMAP:-}" ]]; then
    msgInfo "REMAP $SIL_REMAP"
    remapAdd "$SIL_REMAP" || status=1
fi
if [[ -n "${SIL_LINK:-}" ]]; then
    msgInfo "LINK $SIL_LINK"
    linkTag "$SIL_LINK" || status=1
fi

if (( ${#_silArgs[@]} == 0 )); then
    if ! flagIsSet REBUILD && ! flagIsSet CHECK && [[ -z "${SIL_LINK:-}${SIL_REMAP:-}" ]]; then
        msgInfo "No images or manifests given, nothing more to do"
    fi
    exit "$status"
fi

## Command line paths are relative to the current folder (REQ-03)
for arg in "${_silArgs[@]}"; do
    if [[ -f "$arg" && "${arg,,}" == *.txt ]]; then
        ## REQ-06: manifests are text files with a .txt suffix
        parseManifest "$arg" || status=1
    elif [[ -z "${SIL_LIBRARY:-}" ]]; then
        noLibraryError
    else
        processURI "$arg" || status=1
    fi
done
outcomeSummary
exit "$status"
