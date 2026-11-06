## Tagging - see TAG, UNTAG, LINK and REMAP in docs/parameters.md

srcLib "index"

## Reserved top-level tag for date tags (TAG-02); users can't apply it
declare -g _silDateTag="Date"

## Reserved top-level tag for images with no other tags (TAG-03); kept
## up to date automatically, users can't apply or remove it
declare -g _silUntaggedTag="Untagged"

## Letters allowed in tags beyond ASCII (TAG-03): the accented letters of
## Latin-1. Matched under a UTF-8 locale, as single characters
declare -g _silTagLatin1='ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ'

## Set by applyTags: how many tags the image got or already had
declare -g _silTagsApplied=0

## File of tag remaps in a library (REMAP), kept for hand editing
declare -g _silRemapFile="RemappedTags.txt"

## Remaps in force, keyed by lowercase source tag: the target tag, and the
## source as written. _silRemapsLibrary is the library they were read from
declare -gA _silRemaps=()
declare -gA _silRemapSource=()
declare -g _silRemapsLibrary=""

#######################################
# Split a TAG value into tag paths. Tags are separated by commas; levels
# within a tag by '/' or ':'. Whitespace around each tag and level is
# removed, as are empty levels. Levels keep only the characters allowed
# in tags (TAG-03): letters (ASCII and Latin-1 accented), digits, space,
# '_' and '-'; a tag changed by this is warned about. A tag with a level
# left empty (eg '.', '..' or '!!') is left out, so a tag can never
# reach outside the tags folder.
#   'Humor , Animal:Mammal/ Dog' -> 'Humor' and 'Animal/Mammal/Dog'
#   'Fun!' -> 'Fun', with a warning
# Globals:
#   _silTagLatin1
# Arguments:
#   $1 - TAG value
# Outputs:
#   One tag path per line to STDOUT, levels joined with '/'; warnings
#   to STDERR
# Returns:
#   0 on success; 1 if any tag was left out
#######################################
function parseTags {
    local LC_ALL=C.UTF-8
    local tag level clean path given rv=0
    local -a tags levels
    IFS=',' read -r -a tags <<< "$1"
    for tag in "${tags[@]}"; do
        IFS='/:' read -r -a levels <<< "$tag"
        path=""
        given=""
        for level in "${levels[@]}"; do
            level="$(trim "$level")"
            [[ -z "$level" ]] && continue
            given="${given:+$given/}$level"
            clean="$(trim "${level//[^a-zA-Z0-9 _${_silTagLatin1}-]/}")"
            if [[ -z "$clean" ]]; then
                msgWarn "[!] Tag '$(trim "$tag")' ignored: '$level' has no characters allowed in tags (letters, digits, space, _ and -)"
                rv=1
                continue 2
            fi
            path="${path:+$path/}$clean"
        done
        [[ "$path" != "$given" ]] && msgWarn "[!] Tag '$given' renamed to '$path'"
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
    ## Case-insensitive for accented letters too
    local LC_ALL=C.UTF-8
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
    linkImageInto "$1" "$(realpath -- "$dir")"
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
# The reserved tag a tag path falls under, if any: the date tag (TAG-02)
# or the Untagged tag (TAG-03), matched case-insensitively.
# Globals:
#   _silDateTag, _silUntaggedTag
# Arguments:
#   $1 - Tag path, eg Date/2026
# Outputs:
#   The reserved tag's name to STDOUT
# Returns:
#   0 if reserved, 1 otherwise
#######################################
function reservedTag {
    local top="${1%%/*}" reserved
    for reserved in "$_silDateTag" "$_silUntaggedTag"; do
        if [[ "${top,,}" == "${reserved,,}" ]]; then
            printf '%s\n' "$reserved"
            return 0
        fi
    done
    return 1
}

#######################################
# Split a TAG or UNTAG value into tag paths (parseTags), each changed to
# what it is remapped to (REMAP) and listed once, leaving out any the user
# may not use: the reserved date and Untagged tags (reservedTag), and tags
# parseTags leaves out.
# Globals:
#   _silDateTag, _silRemaps
# Arguments:
#   $1 - TAG or UNTAG value
#   $2 - 'TAG' (default) or 'UNTAG', for the warnings given
# Outputs:
#   One tag path per line to STDOUT; warnings for any left out to STDERR
# Returns:
#   0 if every tag was usable, 1 if any was left out
#######################################
function parseUserTags {
    local LC_ALL=C.UTF-8
    local tags tag reserved rv=0
    local -A seen=()
    tags="$(parseTags "$1")" || rv=1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        tag="$(remapTag "$tag")" || msgWarn "[!] Remaps of tag '$tag' loop; not remapped"
        [[ -n "${seen[${tag,,}]:-}" ]] && continue
        seen[${tag,,}]=1
        if reserved="$(reservedTag "$tag")"; then
            if [[ "$reserved" == "$_silDateTag" ]]; then
                msgWarn "[!] '$_silDateTag' is reserved for automatic date tags - ignored: $tag"
            elif [[ "${2:-TAG}" == UNTAG ]]; then
                msgWarn "[!] '$reserved' is added and removed automatically - ignored. To remove all tags from an image, use 'UNTAG=*'"
            else
                msgWarn "[!] '$reserved' is a reserved tag - if you wish to remove all tags from an image, use 'UNTAG=*'"
            fi
            rv=1
            continue
        fi
        printf '%s\n' "$tag"
    done <<< "$tags"
    return "$rv"
}

#######################################
# Apply every tag in SIL_TAG to a stored image. An image given any tag
# loses its Untagged tag (TAG-03).
# Globals:
#   SIL_TAG; sets _silTagsApplied
# Arguments:
#   $1 - Image hash
# Outputs:
#   Applied tags, marking any the image already had '(existed)', and
#   problems, to STDERR
# Returns:
#   0 on success, 1 if any tag could not be applied
#######################################
function applyTags {
    local tags tag link existed rv=0 applied=""
    _silTagsApplied=0
    [[ -n "${SIL_TAG:-}" ]] || return 0
    syncRemaps || rv=1
    tags="$(parseUserTags "$SIL_TAG" TAG)" || rv=1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        existed=""
        link="$(tagLinkPath "$1" "$tag")" && [[ -L "$link" ]] && existed=" (existed)"
        if tagImage "$1" "$tag"; then
            applied="${applied:+$applied, }$tag$existed"
            _silTagsApplied=$(( _silTagsApplied + 1 ))
        else
            msgWarn "[!] Could not apply tag: $tag"
            rv=1
        fi
    done <<< "$tags"
    [[ -n "$applied" ]] && msgInfo "  Tagged: $applied"
    (( _silTagsApplied )) && dropUntagged "$1"
    return "$rv"
}

#######################################
# Give a stored image the Untagged tag (TAG-03).
# Globals:
#   SIL_LIBRARY, _silUntaggedTag
# Arguments:
#   $1 - Image hash
# Returns:
#   0 on success, 1 if the image isn't stored or the link can't be made
#######################################
function markUntagged {
    local dir="$SIL_LIBRARY/tags/$_silUntaggedTag"
    mkdir -p -- "$dir" || return 1
    linkImageInto "$1" "$(realpath -- "$dir")"
}

#######################################
# Remove the Untagged tag (TAG-03) from a stored image, if it has it. The
# folder is removed if left empty; it can't be a LINK target, so the
# fuller checks of pruneTagFolder aren't needed.
# Globals:
#   _silUntaggedTag
# Arguments:
#   $1 - Image hash
#######################################
function dropUntagged {
    local link
    link="$(tagLinkPath "$1" "$_silUntaggedTag")" && [[ -L "$link" ]] || return 0
    rm -f -- "$link"
    rmdir -- "$(dirname -- "$link")" 2> /dev/null || true
}

#######################################
# Find a stored image's links in user tags: every tag except the date
# and Untagged tags. Links through a LINK alias aren't followed, so each
# tag is found once, at its real folder.
# Globals:
#   SIL_LIBRARY, _silDateTag, _silUntaggedTag
# Arguments:
#   $1 - Image hash
#   $2 - 'first' to stop at the first link found
# Outputs:
#   One link path (physical) per line to STDOUT
# Returns:
#   0 on success, 1 if the image isn't stored
#######################################
function userTagLinks {
    local image root
    local -a quit=()
    image="$(findStoredImage "$1")" || return 1
    root="$(realpath -- "$SIL_LIBRARY/tags")"
    [[ "${2:-}" == first ]] && quit=(-quit)
    find "$root" \( -path "$root/$_silDateTag" -o -path "$root/$_silUntaggedTag" \) -prune \
        -o -type l -name "${image##*/}" -print "${quit[@]}"
}

#######################################
# Test whether a stored image has any user tag (userTagLinks).
# Arguments:
#   $1 - Image hash
# Returns:
#   0 if it has, 1 otherwise
#######################################
function hasUserTags {
    [[ -n "$(userTagLinks "$1" first)" ]]
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
# Path a stored image's link would have in an existing tag's folder,
# whether or not the link exists. Nothing is created.
# Arguments:
#   $1 - Image hash
#   $2 - Tag path, eg Animal/Dog
# Outputs:
#   The link path to STDOUT
# Returns:
#   0 on success, 1 if the tag folder doesn't exist or the image isn't
#   stored
#######################################
function tagLinkPath {
    local dir image
    dir="$(tagFolder "$2" find)" || return 1
    image="$(findStoredImage "$1")" || return 1
    printf '%s\n' "$dir/$(basename -- "$image")"
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
    local link
    link="$(tagLinkPath "$1" "$2")" && [[ -L "$link" ]] || return 1
    rm -f -- "$link"
    pruneTagFolder "$(dirname -- "$link")"
}

#######################################
# Remove every tag in SIL_UNTAG from a stored image. '*' removes all of
# its tags, except its date tag. An image left with no tags is given the
# Untagged tag (TAG-03).
# Globals:
#   SIL_UNTAG, SIL_LIBRARY
# Arguments:
#   $1 - Image hash
# Outputs:
#   Removed tags, tags the image didn't have, and problems, to STDERR
# Returns:
#   0 on success, 1 if any tag could not be used
#######################################
function applyUntags {
    local tags tag link root rv=0 removed="" absent=""
    [[ -n "${SIL_UNTAG:-}" ]] || return 0
    if [[ ",$SIL_UNTAG," =~ ,[[:space:]]*\*[[:space:]]*, ]]; then
        root="$(realpath -- "$SIL_LIBRARY/tags")"
        while IFS= read -r link; do
            [[ -n "$link" ]] || continue
            rm -f -- "$link"
            tag="$(dirname -- "$link")"
            removed="${removed:+$removed, }${tag#"$root"/}"
            pruneTagFolder "$tag"
        done <<< "$(userTagLinks "$1" | LC_ALL=C sort)"
        if [[ -n "$removed" ]]; then
            msgInfo "  Untagged: $removed"
        else
            msgInfo "  Had no tags to remove"
        fi
        markUntagged "$1" || rv=1
        return "$rv"
    fi

    syncRemaps || rv=1
    tags="$(parseUserTags "$SIL_UNTAG" UNTAG)" || rv=1
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
    if [[ -n "$removed" ]] && ! hasUserTags "$1"; then
        markUntagged "$1" || rv=1
    fi
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
# (matched case-insensitively, as tags are). Links to images and folders
# are made again, to point correctly from their new place; other files
# are moved.
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
        if [[ -L "$item" ]] && image="$(realpath -e -- "$item" 2> /dev/null)"; then
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
# Split a 'SOURCE -> TARGET' value (LINK, REMAP) into two tag paths. Neither
# may be a reserved tag (reservedTag).
# Arguments:
#   $1 - Parameter name, for messages
#   $2 - Value, eg 'Politics -> Meme/Politics'
#   $3 - Name of the variable to set to the source tag path
#   $4 - Name of the variable to set to the target tag path
#   $5 - Optional location of the value, for messages
# Outputs:
#   Problems to STDERR
# Returns:
#   0 on success, 1 if the value is invalid
#######################################
function parseTagPair {
    local _param="$1" _value="$2" _src _target _reserved
    local _where="${5:+$'\n'    Found in: $5}"
    if [[ "$_value" != *"->"* || "$_value" == *"->"*"->"* ]]; then
        msgWarn "[!] $_param needs a source and target, eg: $_param='Source -> Target'
    Got: $_value$_where"
        return 1
    fi
    _src="$(parseTags "${_value%%->*}")"
    _target="$(parseTags "${_value#*->}")"
    if [[ -z "$_src" || -z "$_target" || "$_src" == *$'\n'* || "$_target" == *$'\n'* ]]; then
        msgWarn "[!] $_param needs exactly one source and one target tag: $_value$_where"
        return 1
    fi
    if _reserved="$(reservedTag "$_src")" || _reserved="$(reservedTag "$_target")"; then
        msgWarn "[!] '$_reserved' is a reserved tag; it can't be used in a $_param: $_value$_where"
        return 1
    fi
    printf -v "$3" '%s' "$_src"
    printf -v "$4" '%s' "$_target"
}

#######################################
# Make one tag an alias of another (LINK): replace the source tag with a
# link to the target tag's folder. The target is created if needed. A
# source holding images is merged into the target, only if the user
# agrees (askYesNo); a source that is already a link is pointed at the
# new target. Reserved tags (reservedTag) can't be used on either side. A
# remapped target (REMAP) is followed; a remapped source is refused, as the
# link would be removed by the next run.
# Globals:
#   SIL_LIBRARY, _silRemaps
# Arguments:
#   $1 - LINK value: 'SOURCE -> TARGET', eg 'Politics -> Meme/Politics'
# Outputs:
#   What was done, and problems, to STDERR
# Returns:
#   0 on success, 1 if the value is invalid or the link can't be made;
#   halts (msgError) if the user declines the merge
#######################################
function linkTag {
    local value="$1" src target parent name entry entryDir targetDir parentDir
    local count was
    parseTagPair LINK "$value" src target || return 1
    syncRemaps || :
    if [[ "$(remapTag "$src")" != "$src" ]]; then
        msgWarn "[!] LINK source '$src' is remapped to '$(remapTag "$src")', so can't be a link
    To use it, remove its line from $_silRemapFile: $value"
        return 1
    fi
    target="$(remapTag "$target")" || :

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
# The tag a tag path ends up as after remaps (REMAP). The longest source
# matching the path or its leading levels applies, case-insensitively, so
# with 'Dog -> Animal/Canine', Dog/Puppy becomes Animal/Canine/Puppy. Remaps
# are followed until none applies: A -> B and B -> C make A into C.
# Globals:
#   _silRemaps
# Arguments:
#   $1 - Tag path, eg Dog/Puppy
# Outputs:
#   The final tag path to STDOUT, or the path given if remaps loop
# Returns:
#   0 on success, 1 if remaps loop
#######################################
function remapTag {
    local LC_ALL=C.UTF-8
    local path="$1" head rest hops=0
    ## A chain that doesn't loop uses each remap at most once
    while (( hops <= ${#_silRemaps[@]} )); do
        head="$path"
        rest=""
        while [[ -z "${_silRemaps[${head,,}]:-}" ]]; do
            if [[ "$head" != */* ]]; then
                printf '%s\n' "$path"
                return 0
            fi
            rest="/${head##*/}$rest"
            head="${head%/*}"
        done
        path="${_silRemaps[${head,,}]}$rest"
        hops=$(( hops + 1 ))
    done
    printf '%s\n' "$1"
    return 1
}

#######################################
# Read the library's remap file (REMAP) into memory. The file is only
# read here, never corrected: a problem line is warned about and ignored,
# as are remaps that loop. If a source is listed twice, the last line wins.
# Globals:
#   SIL_LIBRARY, _silRemapFile; sets _silRemaps, _silRemapSource
# Outputs:
#   Problems to STDERR
#######################################
function loadRemaps {
    local LC_ALL=C.UTF-8
    local file="$SIL_LIBRARY/$_silRemapFile"
    local line lineNum=0 src target key
    local -a keys
    _silRemaps=()
    _silRemapSource=()
    [[ -f "$file" ]] || return 0
    if [[ ! -r "$file" ]]; then
        msgWarn "[!] Can't read $file; tags won't be remapped"
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNum=$(( lineNum + 1 ))
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        parseTagPair REMAP "$line" src target "$file line $lineNum" || continue
        key="${src,,}"
        if [[ "${target,,}" == "$key" || "${target,,}" == "$key"/* ]]; then
            msgWarn "[!] REMAP target can't be its source or inside it: $line
    Found in: $file line $lineNum"
            continue
        fi
        if [[ -n "${_silRemaps[$key]:-}" && "${_silRemaps[$key],,}" != "${target,,}" ]]; then
            msgWarn "[!] REMAP source '$src' is listed more than once; using '$target'
    Found in: $file line $lineNum"
        fi
        _silRemaps[$key]="$target"
        _silRemapSource[$key]="$src"
    done < "$file"

    (( ${#_silRemaps[@]} )) || return 0
    mapfile -t keys < <(printf '%s\n' "${!_silRemaps[@]}" | LC_ALL=C sort)
    for key in "${keys[@]}"; do
        if ! remapTag "${_silRemapSource[$key]}" > /dev/null; then
            msgWarn "[!] REMAP loops, ignored: ${_silRemapSource[$key]} -> ${_silRemaps[$key]}
    Found in: $file"
            unset '_silRemaps[$key]' '_silRemapSource[$key]'
        fi
    done
}

#######################################
# Point every LINK alias of a folder, or of a folder below it, at the same
# place under a tag, so the folder can go.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - Folder (physical path)
#   $2 - Tag path taking its place
# Outputs:
#   Links changed, to STDERR
# Returns:
#   0 on success, 1 if a link can't be remade
#######################################
function repointTagLinks {
    local from="$1" to="$2" root link dest dir rv=0
    local -a links
    root="$(realpath -- "$SIL_LIBRARY/tags")"
    mapfile -t links < <(find "$root" -type l -xtype d ! -path "$root/$_silDateTag/*")
    for link in "${links[@]}"; do
        dest="$(realpath -- "$link")"
        [[ "$dest" == "$from" || "$dest" == "$from"/* ]] || continue
        dir="$(tagFolder "$to${dest#"$from"}")" || { rv=1; continue; }
        rm -f -- "$link"
        ln -s -- "$(relativePath "$(dirname -- "$link")" "$dir")" "$link" || { rv=1; continue; }
        msgInfo "  Link ${link#"$root"/} now points to $to${dest#"$from"}"
    done
    return "$rv"
}

#######################################
# Clear a remapped tag out of the tag folders: its contents are moved to
# the target, keeping subfolders, and the source folder removed. A source
# that is a LINK alias is only removed, as its images belong to the tag it
# points to. Links to the source are pointed at the target.
# Arguments:
#   $1 - Source tag path, eg Dog
#   $2 - Target tag path, fully remapped, eg Animal/Canine
# Outputs:
#   What was done, including the count of files moved, and problems, to
#   STDERR
# Returns:
#   0 on success or if the source doesn't exist, 1 if it can't be cleared
#######################################
function clearRemappedTag {
    local src="$1" target="$2" parentDir entry entryDir targetDir count files
    if [[ "$src" == */* ]]; then
        parentDir="$(tagFolder "${src%/*}" find)" || return 0
    else
        parentDir="$(realpath -- "$SIL_LIBRARY/tags")"
    fi
    entry="$(tagEntry "$parentDir" "${src##*/}")" || return 0
    if [[ -L "$entry" ]]; then
        rm -f -- "$entry"
        msgInfo "  Removed link $src, as it is remapped to $target"
        pruneTagFolder "$parentDir"
        return 0
    fi

    entryDir="$(realpath -- "$entry")"
    if ! targetDir="$(tagFolder "$target")"; then
        msgWarn "[!] Could not create tag folder for $target; $src left in place"
        return 1
    fi
    if [[ "$targetDir" == "$entryDir" || "$targetDir" == "$entryDir"/* ]]; then
        msgWarn "[!] REMAP target '$target' is inside source '$src' (through a LINK); $src left in place"
        pruneTagFolder "$targetDir"
        return 1
    fi
    if ! repointTagLinks "$entryDir" "$target"; then
        msgWarn "[!] Some links to $src could not be changed; $src left in place"
        return 1
    fi
    count="$(find "$entryDir" -mindepth 1 ! -type d | wc -l)"
    if (( count )); then
        if ! moveTagContents "$entryDir" "$target"; then
            msgWarn "[!] Some of $src could not be moved to $target; left in place"
            return 1
        fi
        files="files"
        (( count == 1 )) && files="file"
        msgInfo "  Moved $count $files from $src to $target"
    fi
    find "$entryDir" -mindepth 1 -depth -type d -empty -delete
    pruneTagFolder "$entryDir"
    pruneTagFolder "$targetDir"
}

#######################################
# Bring the library in line with its remap file, once per run for each
# library used: read the file (loadRemaps), which may have been edited by
# hand, and clear out any source tag that has a folder (clearRemappedTag).
# Sources below others go first, so each moves to its own target.
# Globals:
#   SIL_LIBRARY, _silRemaps, _silRemapSource; sets _silRemapsLibrary
# Outputs:
#   What was done, and problems, to STDERR
# Returns:
#   0 on success or with no library yet, 1 if a tag can't be cleared
#######################################
function syncRemaps {
    local key rv=0
    local -a keys
    [[ -n "${SIL_LIBRARY:-}" && "$_silRemapsLibrary" != "$SIL_LIBRARY" ]] || return 0
    _silRemapsLibrary="$SIL_LIBRARY"
    loadRemaps
    (( ${#_silRemaps[@]} )) || return 0
    mapfile -t keys < <(printf '%s\n' "${!_silRemaps[@]}" | LC_ALL=C sort -r)
    for key in "${keys[@]}"; do
        clearRemappedTag "${_silRemapSource[$key]}" \
            "$(remapTag "${_silRemapSource[$key]}")" || rv=1
    done
    return "$rv"
}

#######################################
# Write a remap to the library's remap file, created with a header if
# needed. Any line for the same source is replaced; all others, including
# comments and lines with problems, are kept as they are.
# Globals:
#   SIL_LIBRARY, _silRemapFile
# Arguments:
#   $1 - Source tag path
#   $2 - Target tag path
# Returns:
#   0 on success, 1 if the file can't be written
#######################################
function writeRemap {
    local LC_ALL=C.UTF-8
    local file="$SIL_LIBRARY/$_silRemapFile" new="$1 -> $2" key="${1,,}"
    local line trimmed src out="" placed=0
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="$(trim "$line")"
            if [[ "$trimmed" != \#* && "$trimmed" == *"->"* ]]; then
                src="$(parseTags "${trimmed%%->*}" 2> /dev/null)"
                if [[ "${src,,}" == "$key" ]]; then
                    (( placed )) || out+="$new"$'\n'
                    placed=1
                    continue
                fi
            fi
            out+="$line"$'\n'
        done < "$file"
    else
        out+="# Remapped tags - see REMAP in SIL's docs/parameters.md
#
# One remap per line, as: Source -> Target
# A tag given as Source is applied as Target instead. Case doesn't matter, and
# tags below Source follow it, so with 'Dog -> Animal/Canine', Dog/Puppy becomes
# Animal/Canine/Puppy.
#
# This file can be edited directly. SIL acts on changes the next time it runs,
# moving any files found in a Source tag to its Target. To stop remapping a tag,
# delete its line. Blank lines and lines starting with # are ignored.
"
    fi
    (( placed )) || out+="$new"$'\n'
    printf '%s' "$out" > "$file"
}

#######################################
# Remap one tag to another (REMAP): from now on, the source is quietly
# applied as the target (see remapTag and parseUserTags). The remap is
# saved in the library's remap file, and the source folder, if any, cleared
# out (clearRemappedTag). Reserved tags (reservedTag) can't be used.
# Globals:
#   SIL_LIBRARY, _silRemapFile; updates _silRemaps, _silRemapSource
# Arguments:
#   $1 - REMAP value: 'SOURCE -> TARGET', eg 'Dog -> Animal/Canine'
# Outputs:
#   What was done, and problems, to STDERR
# Returns:
#   0 on success, 1 if the value is invalid, the remap would loop, or the
#   source can't be cleared
#######################################
function remapAdd {
    local LC_ALL=C.UTF-8
    local value="$1" src target key was wasSource
    parseTagPair REMAP "$value" src target || return 1
    key="${src,,}"
    if [[ "${target,,}" == "$key" || "${target,,}" == "$key"/* ]]; then
        msgWarn "[!] REMAP target can't be its source or inside it: $value"
        return 1
    fi
    syncRemaps || :
    was="${_silRemaps[$key]:-}"
    wasSource="${_silRemapSource[$key]:-}"
    if [[ "${was,,}" == "${target,,}" ]]; then
        msgInfo "  Already remapped: $src -> $was"
        return 0
    fi

    _silRemaps[$key]="$target"
    _silRemapSource[$key]="$src"
    if ! remapTag "$src" > /dev/null; then
        msgWarn "[!] REMAP would loop with another remap, ignored: $value
    To change it, edit: $SIL_LIBRARY/$_silRemapFile"
        if [[ -n "$was" ]]; then
            _silRemaps[$key]="$was"
            _silRemapSource[$key]="$wasSource"
        else
            unset '_silRemaps[$key]' '_silRemapSource[$key]'
        fi
        return 1
    fi
    if ! writeRemap "$src" "$target"; then
        msgWarn "[!] Could not save the remap to: $SIL_LIBRARY/$_silRemapFile"
        return 1
    fi
    msgInfo "  Remapped: $src -> $target${was:+, was $was}"
    clearRemappedTag "$src" "$(remapTag "$src")"
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
