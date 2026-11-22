## Manifest handling - see REQ-06

srcLib "params"
srcLib "ingest"
srcLib "report"
srcLib "library"
srcLib "copy"

## Parameters that can't change within a manifest
declare -gA _silManifestBlocked=(
    [CHECK]="it is an action on the whole library; run sil CHECK"
    [REBUILD]="it is an action on the whole library; run sil REBUILD"
    [BUILDWEB]="it is an action on the whole library; run sil BUILDWEB"
    [SHARED]="it applies to the whole library; set it in sil.conf"
)

#######################################
# Process a manifest (REQ-06). Parameter lines change settings for the
# URIs after them; every other line is a URI. Relative paths are
# relative to the manifest's folder. Unless the command line names a
# library, a manifest inside a library starts out using it. LIBRARY may be
# set before the first URI, and the library's settings are then loaded
# (REQ-02). LINK and REMAP
# are carried out at their line, LINK waiting for the user if it must ask.
# GITWEB is recorded in the web page's stamp at its line, so it lasts.
# STOPSIL ends the manifest at its line, leaving the remaining lines unread.
# A COPY or MOVE line starts a block: the hashes on the lines after it are
# copied or moved to another library (copyStored), until any other line
# (comments and blank lines aside) ends it. STOPCOPY and STOPMOVE do
# nothing but end a block, for legibility. Each
# setting other than TAG and UNTAG is echoed with its previous value, so
# overrides of the library's settings are visible. Settings,
# including the library, are restored afterwards, so each manifest is
# self-contained. Outcomes are logged beside the
# manifest in <manifest>.err (failures, as a manifest) and <manifest>.md
# (report), overwriting earlier logs (REQ-08); if SIL halts part way, eg
# when the user declines a LINK, they are finished first (logHalted). A
# library locked by another run halts with the logs untouched (REQ-12).
# A manifest can't name another manifest: only the command line runs
# them, so a .txt line here is a URI like any other (NOTIMAGE).
# Globals:
#   SIL_<NAME> (changed, then restored); sets _silHaltHook
# Arguments:
#   $1 - Manifest path
# Outputs:
#   Progress and outcomes to STDERR
# Returns:
#   0 if every URI succeeded, 1 otherwise
#######################################
function parseManifest {
    local path="$1"
    local base line lineNum=0 canon lib home was now rv=0 urisSeen=0
    local mode value
    local -a tokens=()

    if [[ ! -f "$path" || ! -r "$path" ]]; then
        msgWarn "[!] Manifest not found or not readable: $path"
        return 1
    fi
    base="$(dirname -- "$(realpath -- "$path")")"
    msgInfo "Manifest: $path"
    saveParams
    logStart "$path" || :
    _silHaltHook=logHalted

    if ! cliHasParam LIBRARY && home="$(findLibrary "$base")" \
        && [[ "$home" != "${SIL_LIBRARY:-}" ]]; then
        useLibrary "$home"
        reloadParamsForLibrary "$home"
        msgInfo "  Library: $home (contains this manifest)"
        syncRemaps || rv=1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNum=$(( lineNum + 1 ))
        ## Only whole lines starting with '#' are comments, so URLs
        ## containing '#' survive
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if copyBlockLine "$line" "$base" mode value; then
            openCopyBlock "$mode" "$value" "$base" "$path line $lineNum" || rv=1
            continue
        fi
        if [[ -n "$_silCopyMode" ]]; then
            if [[ "$line" =~ ^[0-9A-Fa-f]{40}$ ]]; then
                urisSeen=1
                logErrBegin
                copyStored "$line" "$lineNum" "${tokens[@]}" || rv=1
                logOutcome "$line"
                continue
            fi
            closeCopyBlock
        fi

        if isParamToken "$line"; then
            canon="$(paramCanonical "$(trim "${line%%=*}")")"
            if [[ -n "${_silManifestBlocked[$canon]:-}" ]]; then
                msgWarn "[!] $canon can't be set in a manifest - ignored
    Reason: ${_silManifestBlocked[$canon]}
    Found in: $path line $lineNum"
                continue
            fi
            if [[ "$canon" == LIBRARY ]]; then
                if (( urisSeen )); then
                    msgWarn "[!] LIBRARY must come before the first URI - ignored
    Found in: $path line $lineNum"
                    rv=1
                    continue
                fi
                setParamToken "$line" "$path line $lineNum"
                lib="$SIL_LIBRARY"
                [[ "$lib" == /* || "$lib" == "~"* ]] || lib="$base/$lib"
                useLibrary "$lib"
                reloadParamsForLibrary "$SIL_LIBRARY" "${tokens[@]}"
                msgInfo "  Library: $SIL_LIBRARY (line $lineNum)"
                syncRemaps || rv=1
                continue
            fi
            if [[ "$canon" == LINK || "$canon" == REMAP ]]; then
                if [[ -z "${SIL_LIBRARY:-}" ]]; then
                    msgWarn "[!] $canon needs a library - ignored
    Found in: $path line $lineNum"
                    rv=1
                    continue
                fi
                logErrBegin
                setParamToken "$line" "$path line $lineNum"
                msgInfo "  $canon (line $lineNum)"
                if [[ "$canon" == LINK ]]; then
                    linkTag "$SIL_LINK" || rv=1
                else
                    remapAdd "$SIL_REMAP" || rv=1
                fi
                continue
            fi
            ## Kept in the web page's stamp at once, as manifest settings
            ## are undone when it ends
            if [[ "$canon" == GITWEB ]]; then
                if [[ -z "${SIL_LIBRARY:-}" ]]; then
                    msgWarn "[!] GITWEB needs a library - ignored
    Found in: $path line $lineNum"
                    rv=1
                    continue
                fi
                setParamToken "$line" "$path line $lineNum"
                msgInfo "  GITWEB (line $lineNum)"
                srcLib "web"
                webStamp || rv=1
                flagIsSet BUILDWEB || webGitNote
                continue
            fi
            ## Only end a block, which the line has done already
            [[ "$canon" == STOPCOPY || "$canon" == STOPMOVE ]] && continue
            if [[ "$canon" == STOPSIL ]]; then
                setParamToken "$line" "$path line $lineNum"
                if flagIsSet STOPSIL; then
                    msgInfo "  STOPSIL: rest of manifest skipped (line $lineNum)"
                    break
                fi
                continue
            fi
            was="$(paramValueText "$canon")"
            setParamToken "$line" "$path line $lineNum"
            tokens+=("$line")
            ## TAG and UNTAG aren't echoed: the tags applied are shown
            ## for each image instead
            if [[ "$canon" != TAG && "$canon" != UNTAG ]]; then
                now="$(paramValueText "$canon")"
                if [[ "$now" == "$was" ]]; then
                    msgInfo "  $canon = $now, unchanged (line $lineNum)"
                else
                    msgInfo "  $canon = $now, was $was (line $lineNum)"
                fi
            fi
        elif looksLikeParam "$line" && [[ ! -e "$base/$line" ]]; then
            msgWarn "[!] Unrecognized parameter '$(trim "${line%%=*}")' - ignored
    Found in: $path line $lineNum"
            rv=1
        else
            ## A COPY or MOVE block names its own libraries, so URIs may
            ## have been seen without one
            if [[ -z "${SIL_LIBRARY:-}" ]]; then
                if (( urisSeen )); then
                    msgWarn "[!] No library for the URIs from line $lineNum - rest of manifest skipped: $path"
                else
                    msgWarn "[!] No library for this manifest - skipped: $path"
                fi
                msgWarn "    Set LIBRARY at the top of the manifest, give one on the command line,
    or keep the manifest inside a library folder"
                rv=1
                break
            fi
            urisSeen=1
            logErrBegin
            processURI "$line" "$base" "$lineNum" || rv=1
            logOutcome "$line"
        fi
    done < "$path"

    closeCopyBlock
    logFinish
    _silHaltHook=""
    restoreParams
    return "$rv"
}
