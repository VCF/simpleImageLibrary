## Tagging - see TAG, UNTAG and LINK in docs/parameters.md

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
# Find the entry in a folder whose name matches a tag level
# case-insensitively: a tag folder, or a link to one (LINK).
# Arguments:
#   $1 - Folder to look in
#   $2 - Tag level, eg Dog
# Outputs:
#   The entry's path (not resolved) to STDOUT
# Returns:
#   0 if found, 1 otherwise
#######################################
function tagEntry {
    local entry name
    for entry in "$1"/*/; do
        entry="${entry%/}"
        name="${entry##*/}"
        if [[ "${name,,}" == "${2,,}" && -d "$entry" ]]; then
            printf '%s\n' "$entry"
            return 0
        fi
    done
    return 1
}

#######################################
# Find or create the folder for a tag path. Each level reuses an existing
# folder whose name matches case-insensitively, keeping its original
# case; otherwise a folder is created with the case given.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Tag path, eg Animal/Dog
#   $2 - 'find' to only find an existing folder, creating nothing
# Outputs:
#   The folder's physical path (symlinks resolved) to STDOUT
# Returns:
#   0 on success; 1 if a folder can't be created, or with 'find', doesn't
#   exist
#######################################
function tagFolder {
    local dir="$SIL_LIBRARY/tags" level found
    local -a levels
    IFS='/' read -r -a levels <<< "$1"
    for level in "${levels[@]}"; do
        if found="$(tagEntry "$dir" "$level")"; then
            dir="$found"
        elif [[ "${2:-}" == find ]]; then
            return 1
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
# Split a TAG or UNTAG value into tag paths (parseTags), leaving out
# any the user may not use: '.' and '..' levels, and the reserved date
# tag (TAG-02).
# Globals:
#   _silDateTag
# Arguments:
#   $1 - TAG or UNTAG value
# Outputs:
#   One tag path per line to STDOUT; warnings for any left out to STDERR
# Returns:
#   0 if every tag was usable, 1 if any was left out
#######################################
function parseUserTags {
    local tags tag top rv=0
    if ! tags="$(parseTags "$1")"; then
        msgWarn "[!] Ignored tag levels '.' and '..' in: $1"
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
        printf '%s\n' "$tag"
    done <<< "$tags"
    return "$rv"
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
    tags="$(parseUserTags "$SIL_TAG")" || rv=1
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

#######################################
# Test whether a folder is a day folder of the date tag (TAG-02).
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - Folder (physical path)
# Returns:
#   0 if a day folder, 1 otherwise
#######################################
function isDayFolder {
    local root
    root="$(realpath -- "$SIL_LIBRARY/tags/$_silDateTag" 2> /dev/null)" || return 1
    [[ "$1" =~ ^"$root"/[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

#######################################
# Remove a tag folder left empty (eg by UNTAG or REMOVE), then any
# parents left empty, up to the tags folder. A folder that a LINK points
# to is kept, so the link isn't broken. A day folder of the date tag
# counts as empty when only its next/previous links remain; the chain
# of days is then relinked around it.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - Tag folder (physical path)
#######################################
function pruneTagFolder {
    local dir="$1" root targets relink=0
    root="$(realpath -- "$SIL_LIBRARY/tags")"
    ## Links between days (TAG-02) don't count: only LINK aliases
    targets="$(find "$root" -type l -xtype d ! -path "$root/$_silDateTag/*" \
        -exec realpath -- {} + 2> /dev/null)"
    while [[ "$dir" == "$root"/* && -d "$dir" ]]; do
        grep -qxF -- "$dir" <<< "$targets" && break
        if isDayFolder "$dir"; then
            [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 \
                ! -name 'next-*' ! -name 'previous-*')" ]] || break
            find "$dir" -mindepth 1 -maxdepth 1 -type l -delete
            relink=1
        fi
        rmdir -- "$dir" 2> /dev/null || break
        dir="$(dirname -- "$dir")"
    done
    (( relink )) && relinkDays
    return 0
}

#######################################
# Remove a tag from a stored image: its link in the tag's folder. Tags
# below it (eg Animal/Dog for Animal) are not affected. A folder left
# empty is removed (pruneTagFolder).
# Arguments:
#   $1 - Image hash
#   $2 - Tag path, eg Animal/Dog
# Returns:
#   0 if removed, 1 if the image didn't have the tag
#######################################
function untagImage {
    local dir image link
    dir="$(tagFolder "$2" find)" || return 1
    image="$(findStoredImage "$1")" || return 1
    link="$dir/$(basename -- "$image")"
    [[ -L "$link" ]] || return 1
    rm -f -- "$link"
    pruneTagFolder "$dir"
}

#######################################
# Remove every tag in SIL_UNTAG from a stored image.
# Globals:
#   SIL_UNTAG
# Arguments:
#   $1 - Image hash
# Outputs:
#   Removed tags, tags the image didn't have, and problems, to STDERR
# Returns:
#   0 on success, 1 if any tag could not be used
#######################################
function applyUntags {
    local tags tag rv=0 removed="" absent=""
    [[ -n "${SIL_UNTAG:-}" ]] || return 0
    tags="$(parseUserTags "$SIL_UNTAG")" || rv=1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if untagImage "$1" "$tag"; then
            removed="${removed:+$removed, }$tag"
        else
            absent="${absent:+$absent, }$tag"
        fi
    done <<< "$tags"
    [[ -n "$removed" ]] && msgInfo "  Untagged: $removed"
    [[ -n "$absent" ]] && msgInfo "  Did not have tag: $absent"
    return "$rv"
}

#######################################
# Ask the person running SIL a yes/no question, waiting for an answer.
# The question is asked at the terminal, not on STDIN, which may be a
# manifest being read.
# Arguments:
#   $1 - Question
# Returns:
#   0 for yes, 1 for no; halts (msgError) if there is no terminal to ask
#######################################
function askYesNo {
    local answer
    if ! { : < /dev/tty; } 2> /dev/null; then
        msgError "[!] SIL needs an answer, but has no terminal to ask at:
    $1
    Run sil from a terminal"
    fi
    while true; do
        read -r -p "$1 [Y/N] " answer < /dev/tty 2> /dev/tty || answer=""
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

#######################################
# Move the contents of a tag folder into another, keeping subfolders
# (matched case-insensitively, as tags are). Links to images are made
# again, to point correctly from their new place; other files are moved.
# Arguments:
#   $1 - Folder to empty (physical path)
#   $2 - Tag path to move into, eg Meme/Politics
# Returns:
#   0 on success, 1 if anything could not be moved
#######################################
function moveTagContents {
    local from="$1" to="$2" item rel dest image rv=0
    local -a items
    mapfile -t items < <(find "$from" -mindepth 1 ! -type d | sort)
    for item in "${items[@]}"; do
        rel="${item#"$from"/}"
        if [[ "$rel" == */* ]]; then
            dest="$(tagFolder "$to/${rel%/*}")" || { rv=1; continue; }
        else
            dest="$(tagFolder "$to")" || { rv=1; continue; }
        fi
        if [[ -L "$item" ]] && image="$(realpath -e -- "$item" 2> /dev/null)" \
            && [[ -f "$image" ]]; then
            [[ -L "$dest/${item##*/}" ]] \
                || ln -s -- "$(relativePath "$dest" "$image")" "$dest/${item##*/}" \
                || { rv=1; continue; }
            rm -f -- "$item"
        else
            mv -n -- "$item" "$dest/" && [[ ! -e "$item" && ! -L "$item" ]] || rv=1
        fi
    done
    find "$from" -mindepth 1 -depth -type d -empty -delete
    return "$rv"
}

#######################################
# Make one tag an alias of another (LINK): replace the source tag with a
# link to the target tag's folder. The target is created if needed. A
# source holding images is merged into the target, only if the user
# agrees (askYesNo); a source that is already a link is pointed at the
# new target.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - LINK value: 'SOURCE -> TARGET', eg 'Politics -> Meme/Politics'
# Outputs:
#   What was done, and problems, to STDERR
# Returns:
#   0 on success, 1 if the value is invalid or the link can't be made;
#   halts (msgError) if the user declines the merge
#######################################
function linkTag {
    local value="$1" src target top parent name entry entryDir targetDir parentDir
    local count was
    if [[ "$value" != *"->"* ]]; then
        msgWarn "[!] LINK needs a source and target, eg: LINK='Politics -> Meme/Politics'
    Got: $value"
        return 1
    fi
    src="$(parseTags "${value%%->*}")"
    target="$(parseTags "${value#*->}")"
    if [[ -z "$src" || -z "$target" || "$src" == *$'\n'* || "$target" == *$'\n'* ]]; then
        msgWarn "[!] LINK needs exactly one source and one target tag: $value"
        return 1
    fi
    top="${src%%/*}"
    if [[ "${top,,}" == "${_silDateTag,,}" ]]; then
        msgWarn "[!] '$_silDateTag' is reserved for automatic date tags; it can't be a LINK source: $src"
        return 1
    fi

    name="${src##*/}"
    parent=""
    [[ "$src" == */* ]] && parent="${src%/*}"
    targetDir="$(tagFolder "$target")" || return 1
    if [[ -n "$parent" ]]; then
        parentDir="$(tagFolder "$parent")" || return 1
    else
        parentDir="$(realpath -- "$SIL_LIBRARY/tags")"
    fi
    if [[ "$parentDir" == "$targetDir" || "$parentDir" == "$targetDir"/* ]]; then
        msgWarn "[!] LINK source can't be inside its target, it would loop: $value"
        pruneTagFolder "$targetDir"
        return 1
    fi

    if entry="$(tagEntry "$parentDir" "$name")"; then
        name="${entry##*/}"
        if [[ -L "$entry" ]]; then
            was="$(realpath -- "$entry")"
            if [[ "$was" == "$targetDir" ]]; then
                msgInfo "  Already linked: $src -> $target"
                return 0
            fi
            rm -f -- "$entry"
            msgInfo "  Unlinked $src from ${was#"$(realpath -- "$SIL_LIBRARY")"/}"
        elif entryDir="$(realpath -- "$entry")" \
            && [[ "$targetDir" == "$entryDir" || "$targetDir" == "$entryDir"/* ]]; then
            msgWarn "[!] LINK target can't be inside its source, it would loop: $value"
            pruneTagFolder "$targetDir"
            return 1
        else
            count="$(find "$entry" -mindepth 1 ! -type d | wc -l)"
            if (( count )); then
                if ! askYesNo "Source tag '$src' has $count images present - move images to '$target' and replace with symlink?"; then
                    msgError "[!] No changes made: LINK $value"
                fi
                if ! moveTagContents "$entryDir" "$target"; then
                    msgWarn "[!] Some of $src could not be moved to $target; left in place, not linked"
                    return 1
                fi
                msgInfo "  Moved $count images from $src to $target"
            fi
            find "$entry" -depth -type d -empty -delete
            if [[ -e "$entry" ]]; then
                msgWarn "[!] Could not remove the $src folder, not linked"
                return 1
            fi
        fi
    fi

    ln -s -- "$(relativePath "$parentDir" "$targetDir")" "$parentDir/$name" || return 1
    msgInfo "  Linked: ${parent:+$parent/}$name -> $target"
}

#######################################
# Remove a stored image from the library (REMOVE): every tag link to it
# (including its date tag), the image file, and its lines in the
# fingerprint index and sources file. Folders left empty are removed.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Image hash
# Returns:
#   0 on success, 1 if the image isn't stored or can't be removed
#######################################
function removeImage {
    local hash="$1" image link
    local -a links
    image="$(findStoredImage "$hash")" || return 1
    image="$(realpath -- "$image")"
    mapfile -t links < <(find "$SIL_LIBRARY/tags" -type l -name "${image##*/}")
    for link in "${links[@]}"; do
        [[ "$(realpath -m -- "$link")" == "$image" ]] || continue
        rm -f -- "$link"
        pruneTagFolder "$(realpath -- "$(dirname -- "$link")")"
    done
    rm -f -- "$image" || return 1
    find "$SIL_LIBRARY/images" -mindepth 1 -type d -empty -delete
    indexRemove "$hash" && sourcesRemove "$hash"
}
