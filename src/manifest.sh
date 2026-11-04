## Manifest handling - see REQ-06

srcLib "params"
srcLib "ingest"
srcLib "report"
srcLib "library"

## Parameters that can't change within a manifest
declare -gA _silManifestBlocked=(
    [CHECK]="it is an action on the whole library; run sil CHECK"
    [REBUILD]="it is an action on the whole library; run sil REBUILD"
)

#######################################
# Process a manifest (REQ-06). Parameter lines change settings for the
# URIs after them; every other line is a URI. Relative paths are
# relative to the manifest's folder. LIBRARY may be set before the first
# URI, and the library's settings are then loaded (REQ-02). LINK is
# carried out at its line, waiting for the user if it must ask. STOPSIL
# ends the manifest at its line, leaving the remaining lines unread. Each
# setting other than TAG and UNTAG is echoed with its previous value, so
# overrides of the library's settings are visible. Settings,
# including the library, are restored afterwards, so each manifest is
# self-contained. Outcomes are logged beside the
# manifest in <manifest>.err (failures, as a manifest) and <manifest>.md
# (report), overwriting earlier logs (REQ-08).
# Globals:
#   SIL_<NAME> (changed, then restored)
# Arguments:
#   $1 - Manifest path
# Outputs:
#   Progress and outcomes to STDERR
# Returns:
#   0 if every URI succeeded, 1 otherwise
#######################################
function parseManifest {
    local path="$1"
    local base line lineNum=0 canon lib was now rv=0 urisSeen=0
    local -a tokens=()

    if [[ ! -f "$path" || ! -r "$path" ]]; then
        msgWarn "[!] Manifest not found or not readable: $path"
        return 1
    fi
    base="$(dirname -- "$(realpath -- "$path")")"
    msgInfo "Manifest: $path"
    saveParams
    logStart "$path" || :

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNum=$(( lineNum + 1 ))
        ## Only whole lines starting with '#' are comments, so URLs
        ## containing '#' survive
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue

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
                continue
            fi
            if [[ "$canon" == LINK ]]; then
                if [[ -z "${SIL_LIBRARY:-}" ]]; then
                    msgWarn "[!] LINK needs a library - ignored
    Found in: $path line $lineNum"
                    rv=1
                    continue
                fi
                setParamToken "$line" "$path line $lineNum"
                msgInfo "  LINK (line $lineNum)"
                linkTag "$SIL_LINK" || rv=1
                continue
            fi
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
            if (( ! urisSeen )) && [[ -z "${SIL_LIBRARY:-}" ]]; then
                msgWarn "[!] No library for this manifest - skipped: $path
    Set LIBRARY at the top of the manifest, or give one on the command line"
                rv=1
                break
            fi
            urisSeen=1
            processURI "$line" "$base" "$lineNum" || rv=1
            logOutcome "$line"
        fi
    done < "$path"

    logFinish
    restoreParams
    return "$rv"
}
