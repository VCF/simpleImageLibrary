# Manifest handling functions


function parseManifest {
    ## Parse a manifest file
    local path="$1"  # The file we are going to parse
    
    ## Confirm path is ok
    if [[ -z "$path" ]]; then
        msgError "[!] parseManifest must be provided with a file path as first argument"
    elif [[ ! -f "$path" ]]; then
        msgError "[!] parseManifest - file not found: $path"
    elif [[ ! -s "$path" ]]; then
        msgWarn "[!] parseManifest - file is empty: $path"
    fi

    ## Read the manifest line-by-line. Per REQ-06 only whole lines starting
    ## with '#' are comments, so URLs containing '#' survive
    srcLib "params"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        msgInfo "$line"
    done < "$path"
    
}

#######################################
# Recover and ingest an image from a URI: URL, local path or image hash
# (REQ-03, REQ-04). Not yet implemented.
# Arguments:
#   $1 - The URI
# Returns:
#   1 (not implemented)
#######################################
function processURI {
    msgWarn "[!] Adding images is not yet implemented, skipping: $1"
    return 1
}
