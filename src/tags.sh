## Tagging - see TAG in docs/parameters.md

srcLib "index"

#######################################
# Split a TAG value into tag paths. Tags are separated by commas; levels
# within a tag by '/' or ':'. Whitespace around each tag and level is
# removed, as are empty levels.
#   'Humor , Animal:Mammal/ Dog' -> 'Humor' and 'Animal/Mammal/Dog'
# Arguments:
#   $1 - TAG value
# Outputs:
#   One tag path per line to STDOUT, levels joined with '/'
# Returns:
#   0 on success; 1 if any level is '.' or '..', which could reach
#   outside the tags folder
#######################################
function parseTags {
    local tag level path rv=0
    local -a tags levels
    IFS=',' read -r -a tags <<< "$1"
    for tag in "${tags[@]}"; do
        IFS='/:' read -r -a levels <<< "$tag"
        path=""
        for level in "${levels[@]}"; do
            level="$(trim "$level")"
            [[ -z "$level" ]] && continue
            if [[ "$level" == . || "$level" == .. ]]; then
                rv=1
                continue 2
            fi
            path="${path:+$path/}$level"
        done
        [[ -n "$path" ]] && printf '%s\n' "$path"
    done
    return "$rv"
}

#######################################
# Find or create the folder for a tag path. Each level reuses an existing
# folder whose name matches case-insensitively, keeping its original
# case; otherwise a folder is created with the case given.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Tag path, eg Animal/Dog
# Outputs:
#   The folder's physical path (symlinks resolved) to STDOUT
# Returns:
#   0 on success, 1 if a folder can't be created
#######################################
function tagFolder {
    local dir="$SIL_LIBRARY/tags" level entry name found
    local -a levels
    IFS='/' read -r -a levels <<< "$1"
    for level in "${levels[@]}"; do
        found=""
        for entry in "$dir"/*/; do
            entry="${entry%/}"
            name="${entry##*/}"
            if [[ "${name,,}" == "${level,,}" ]]; then
                found="$entry"
                break
            fi
        done
        if [[ -n "$found" && -d "$found" ]]; then
            dir="$found"
        else
            dir="$dir/$level"
            mkdir -p -- "$dir" || return 1
        fi
    done
    realpath -- "$dir"
}

#######################################
# Tag a stored image: link to it from the tag's folder (TAG-01). The link
# is named after the image file and points to it by relative path.
# Existing links are left as they are.
# Arguments:
#   $1 - Image hash
#   $2 - Tag path, eg Animal/Dog
# Returns:
#   0 on success, 1 if the image isn't stored or the link can't be made
#######################################
function tagImage {
    local image dir link
    image="$(findStoredImage "$1")" || return 1
    image="$(realpath -- "$image")"
    dir="$(tagFolder "$2")" || return 1
    link="$dir/$(basename -- "$image")"
    [[ -L "$link" ]] && return 0
    ln -s -- "$(relativePath "$dir" "$image")" "$link"
}

#######################################
# Apply every tag in SIL_TAG to a stored image.
# Globals:
#   SIL_TAG
# Arguments:
#   $1 - Image hash
# Outputs:
#   Applied tags, and problems, to STDERR
# Returns:
#   0 on success, 1 if any tag could not be applied
#######################################
function applyTags {
    local tags tag rv=0 applied=""
    [[ -n "${SIL_TAG:-}" ]] || return 0
    if ! tags="$(parseTags "$SIL_TAG")"; then
        msgWarn "[!] Ignored tag levels '.' and '..' in: $SIL_TAG"
        rv=1
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if tagImage "$1" "$tag"; then
            applied="${applied:+$applied, }$tag"
        else
            msgWarn "[!] Could not apply tag: $tag"
            rv=1
        fi
    done <<< "$tags"
    [[ -n "$applied" ]] && msgInfo "  Tagged: $applied"
    return "$rv"
}
