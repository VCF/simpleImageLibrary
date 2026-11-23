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

## Shown to any other sil refused by this run's lock on a library (REQ-12)
_silCommandLine="sil $*"
_silCommandLine="${_silCommandLine//$'\n'/ }"

srcLib "params"
srcLib "library"
srcLib "manifest"
srcLib "maintain"
srcLib "web"

## Tell the open web page of any library this run changes that its data
## is out of date (BUILDWEB), however the run ends
trap stampChangedLibraries EXIT

## REQ-02 precedence: defaults < ~/.sil.conf < library sil.conf < command
## line < manifest
loadParams "$@"

## With no library yet, manifests may name one (REQ-06); anything else
## needs one now
needLibrary=0
if flagIsSet CHECK || flagIsSet REBUILD || flagIsSet BUILDWEB || [[ -n "${SIL_LINK:-}${SIL_REMAP:-}${SIL_GITWEB:-}" ]]; then
    needLibrary=1
fi
for arg in "${_silArgs[@]}"; do
    [[ -f "$arg" && "${arg,,}" == *.txt ]] || needLibrary=1
done
## CHECK and REBUILD may use a library in an older image layout (REQ-05)
maintainMode=""
if flagIsSet CHECK || flagIsSet REBUILD; then
    maintainMode="maintain"
fi
if lib="$(chooseLibrary)"; then
    useLibrary "$lib" "$maintainMode"
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
## Nothing else may change a library still in an older image layout, as
## REBUILD reported (or CHECK, run alone)
if [[ -n "$maintainMode" && -n "${SIL_LIBRARY:-}" ]] && ! layoutProblem "$SIL_LIBRARY" > /dev/null; then
    if (( ${#_silArgs[@]} )) || flagIsSet BUILDWEB || [[ -n "${SIL_LINK:-}${SIL_REMAP:-}${SIL_GITWEB:-}" ]]; then
        msgWarn "[!] Nothing more was done, as the library's images are still in an older layout"
    fi
    exit 1
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
## GITWEB is recorded in the stamp now, and applied to .gitignore by BUILDWEB
if [[ -n "${SIL_GITWEB:-}" ]] && ! flagIsSet BUILDWEB; then
    webStamp || status=1
    webGitNote
fi

if (( ${#_silArgs[@]} == 0 )); then
    if flagIsSet BUILDWEB; then
        buildWeb || status=1
    elif ! flagIsSet REBUILD && ! flagIsSet CHECK && [[ -z "${SIL_LINK:-}${SIL_REMAP:-}${SIL_GITWEB:-}" ]]; then
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
## Last, so the page shows everything this run did. Manifests restore the
## library they started from, so this is the command line's library
if flagIsSet BUILDWEB; then
    buildWeb || status=1
fi
exit "$status"
