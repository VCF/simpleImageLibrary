## Library location and creation - see LIBRARY in docs/parameters.md

#######################################
# Test whether a folder is a SIL library (has 'images' and 'tags').
# Arguments:
#   $1 - Folder path
# Returns:
#   0 if a library, 1 otherwise
#######################################
function isLibrary {
    [[ -d "$1/images" && -d "$1/tags" ]]
}

#######################################
# Find the library containing a folder, checking it and each parent.
# Arguments:
#   $1 - Folder to start from (default: current folder)
# Outputs:
#   Absolute library path to STDOUT
# Returns:
#   0 if found, 1 otherwise
#######################################
function findLibrary {
    local dir
    dir="$(realpath -- "${1:-$PWD}" 2> /dev/null)" || return 1
    while true; do
        if isLibrary "$dir"; then
            printf '%s\n' "$dir"
            return 0
        fi
        [[ "$dir" == / ]] && return 1
        dir="$(dirname -- "$dir")"
    done
}

#######################################
# Create a new library: the folder (if needed), 'images', 'tags', and
# a sil.conf copied from templates/sil.conf.
# Globals:
#   myDir
# Arguments:
#   $1 - Library path
# Returns:
#   0 on success; halts (msgError) if folders can't be created
#######################################
function initLibrary {
    local lib="$1"
    local errTxt
    if ! errTxt="$(mkdir -p -- "$lib/images" "$lib/tags" 2>&1)"; then
        msgError "[!] Could not create library at: $lib
    $errTxt"
    fi
    [[ -e "$lib/sil.conf" ]] || cp -- "$myDir/templates/sil.conf" "$lib/sil.conf"
    msgInfo "Created new library at: $lib
    Library settings can be changed in: $lib/sil.conf"
}

#######################################
# Decide which library to use, creating it if needed, and set
# SIL_LIBRARY to its absolute path. In order of preference:
#   1. LIBRARY from the command line
#   2. The library containing the current folder
#   3. LIBRARY from ~/.sil.conf
# A LIBRARY that doesn't exist, or is an empty folder, is created. A
# leading '~' is expanded, as conf files are not shell-expanded.
# Globals:
#   SIL_LIBRARY, PWD, HOME
# Returns:
#   0 on success; halts (msgError) if no library can be determined, or
#   LIBRARY is a non-empty folder that isn't a library
#######################################
function resolveLibrary {
    local lib="${SIL_LIBRARY:-}"
    local found

    if ! cliHasParam LIBRARY && found="$(findLibrary "$PWD")"; then
        lib="$found"
    fi
    if [[ -z "$lib" ]]; then
        msgError "[!] No image library found
    No LIBRARY was given, and the current folder is not inside a library
    (a folder containing 'images' and 'tags'). Either:
      * Run sil from inside a library folder
      * Give a library on the command line; it is created if needed:
          sil LIBRARY=~/Pictures/sil https://example.com/funny.jpg
      * Set a default library in ~/.sil.conf:
          LIBRARY=~/Pictures/sil"
    fi

    # shellcheck disable=SC2088  # Matching a literal, unexpanded '~'
    [[ "$lib" == "~" || "$lib" == "~/"* ]] && lib="$HOME${lib:1}"
    lib="$(realpath -m -- "$lib")"

    if isLibrary "$lib"; then
        :
    elif [[ ! -e "$lib" ]] || [[ -d "$lib" && -z "$(ls -A -- "$lib")" ]]; then
        initLibrary "$lib"
    elif [[ -d "$lib" ]]; then
        msgError "[!] LIBRARY is not a SIL library, and is not empty: $lib
    SIL won't add its folders to an existing, non-empty folder. Either:
      * Choose a new or empty folder for LIBRARY
      * Make it a library yourself:
          mkdir '$lib/images' '$lib/tags'"
    else
        msgError "[!] LIBRARY is not a folder: $lib"
    fi
    printf -v SIL_LIBRARY '%s' "$lib"
}
