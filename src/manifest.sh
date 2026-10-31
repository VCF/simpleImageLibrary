## Manifest handling - see REQ-06

srcLib "params"
srcLib "ingest"

## Parameters that can't change within a manifest
declare -gA _silManifestBlocked=(
    [LIBRARY]="the library is chosen before the manifest is read"
    [CHECK]="it is an action on the whole library; run sil CHECK"
    [REBUILD]="it is an action on the whole library; run sil REBUILD"
)

#######################################
# Process a manifest (REQ-06). Parameter lines change settings for the
# URIs after them; every other line is a URI. Relative paths are
# relative to the manifest's folder. Settings are restored afterwards,
# so each manifest is self-contained.
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
    local base line lineNum=0 canon rv=0

    if [[ ! -f "$path" || ! -r "$path" ]]; then
        msgWarn "[!] Manifest not found or not readable: $path"
        return 1
    fi
    base="$(dirname -- "$(realpath -- "$path")")"
    msgInfo "Manifest: $path"
    saveParams

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
            setParamToken "$line" "$path line $lineNum"
            msgInfo "  Set $canon (line $lineNum)"
        elif looksLikeParam "$line" && [[ ! -e "$base/$line" ]]; then
            msgWarn "[!] Unrecognized parameter '$(trim "${line%%=*}")' - ignored
    Found in: $path line $lineNum"
            rv=1
        else
            processURI "$line" "$base" || rv=1
        fi
    done < "$path"

    restoreParams
    return "$rv"
}
