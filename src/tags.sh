## Tagging - see TAG in docs/parameters.md

srcLib "index"

## Reserved top-level tag for date tags (TAG-02); users can't apply it
declare -g _silDateTag="Date"

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
    local dir
    dir="$(tagFolder "$2")" || return 1
    linkImageInto "$1" "$dir"
}

#######################################
# Link a stored image into a folder, named after the image file, by
# relative path. An existing link is left as it is.
# Arguments:
#   $1 - Image hash
#   $2 - Folder (physical path, symlinks resolved)
# Returns:
#   0 on success, 1 if the image isn't stored or the link can't be made
#######################################
function linkImageInto {
    local image link
    image="$(findStoredImage "$1")" || return 1
    image="$(realpath -- "$image")"
    link="$2/$(basename -- "$image")"
    [[ -L "$link" ]] && return 0
    ln -s -- "$(relativePath "$2" "$image")" "$link"
}

#######################################
# Today's date, as YYYY-MM-DD in local time. Tests may set _silToday.
# Outputs:
#   Date to STDOUT
#######################################
function todayDate {
    if [[ -n "${_silToday:-}" ]]; then
        printf '%s\n' "$_silToday"
    else
        date '+%Y-%m-%d'
    fi
}

#######################################
# List the day folders of the date tag, oldest first.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Outputs:
#   One physical path per line to STDOUT
#######################################
function dateDayFolders {
    [[ -d "$SIL_LIBRARY/tags/$_silDateTag" ]] || return 0
    find "$(realpath -- "$SIL_LIBRARY/tags/$_silDateTag")" -mindepth 2 -maxdepth 2 -type d \
        -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | LC_ALL=C sort
}

#######################################
# Link two day folders as neighbours: <earlier>/next-<later> and
# <later>/previous-<earlier>, replacing any next/previous links they had.
# Arguments:
#   $1 - Earlier day folder
#   $2 - Later day folder
#######################################
function linkDays {
    local a="$1" b="$2"
    find "$a" -maxdepth 1 -type l -name 'next-*' -delete
    find "$b" -maxdepth 1 -type l -name 'previous-*' -delete
    ln -s -- "$(relativePath "$a" "$b")" "$a/next-$(basename -- "$b")"
    ln -s -- "$(relativePath "$b" "$a")" "$b/previous-$(basename -- "$a")"
}

#######################################
# Give a newly stored image its date tag (TAG-02): a link in
# tags/Date/YYYY/YYYY-MM-DD/ for today. A new day folder is linked into
# the chain of days, between the nearest earlier and later days.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - Image hash
# Outputs:
#   The date applied, to STDERR
# Returns:
#   0 on success, 1 if the link can't be made
#######################################
function dateTagImage {
    local day dir d prev="" next=""
    day="$(todayDate)"
    dir="$SIL_LIBRARY/tags/$_silDateTag/${day:0:4}/$day"
    if [[ ! -d "$dir" ]]; then
        mkdir -p -- "$dir" || return 1
        dir="$(realpath -- "$dir")"
        while IFS= read -r d; do
            [[ "$d" == "$dir" ]] && continue
            if [[ "$(basename -- "$d")" < "$day" ]]; then
                prev="$d"
            elif [[ -z "$next" ]]; then
                next="$d"
            fi
        done < <(dateDayFolders)
        [[ -n "$prev" ]] && linkDays "$prev" "$dir"
        [[ -n "$next" ]] && linkDays "$dir" "$next"
    fi
    linkImageInto "$1" "$(realpath -- "$dir")" || return 1
    msgInfo "  Dated: $day"
}

#######################################
# The next/previous links the chain of day folders should have.
# Outputs:
#   One "<link path> <relative target>" line per link to STDOUT
#######################################
function expectedDayLinks {
    local prev="" d
    while IFS= read -r d; do
        if [[ -n "$prev" ]]; then
            printf '%s %s\n' "$prev/next-$(basename -- "$d")" "$(relativePath "$prev" "$d")"
            printf '%s %s\n' "$d/previous-$(basename -- "$prev")" "$(relativePath "$d" "$prev")"
        fi
        prev="$d"
    done < <(dateDayFolders)
}

#######################################
# The next/previous links the day folders actually have.
# Outputs:
#   One "<link path> <target>" line per link to STDOUT
#######################################
function actualDayLinks {
    [[ -d "$SIL_LIBRARY/tags/$_silDateTag" ]] || return 0
    find "$(realpath -- "$SIL_LIBRARY/tags/$_silDateTag")" -mindepth 3 -maxdepth 3 \
        -type l \( -name 'next-*' -o -name 'previous-*' \) -printf '%p %l\n'
}

#######################################
# Test whether the day folders' next/previous links are as they should
# be (eg not after a git merge of two clones that each added a day).
# Returns:
#   0 if correct, 1 otherwise
#######################################
function dayLinksCorrect {
    [[ "$(expectedDayLinks | LC_ALL=C sort)" == "$(actualDayLinks | LC_ALL=C sort)" ]]
}

#######################################
# Remake every next/previous link between day folders.
# Globals:
#   SIL_LIBRARY, _silDateTag
#######################################
function relinkDays {
    local prev="" d
    while IFS= read -r d; do
        find "$d" -maxdepth 1 -type l \( -name 'next-*' -o -name 'previous-*' \) -delete
    done < <(dateDayFolders)
    while IFS= read -r d; do
        [[ -n "$prev" ]] && linkDays "$prev" "$d"
        prev="$d"
    done < <(dateDayFolders)
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
    local tags tag top rv=0 applied=""
    [[ -n "${SIL_TAG:-}" ]] || return 0
    if ! tags="$(parseTags "$SIL_TAG")"; then
        msgWarn "[!] Ignored tag levels '.' and '..' in: $SIL_TAG"
        rv=1
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        top="${tag%%/*}"
        if [[ "${top,,}" == "${_silDateTag,,}" ]]; then
            msgWarn "[!] '$_silDateTag' is reserved for automatic date tags - ignored: $tag"
            rv=1
            continue
        fi
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
