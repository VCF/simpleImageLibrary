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
# Create any of a library's standard folders and files that are missing
# (REQ-10). Existing files are never changed:
#   images/, tags/, tags/.gitkeep, images/fingerprints.txt and
#   images/sources.txt (headers only), sil.conf, .gitignore and
#   .gitattributes (from templates/)
# The .gitkeep and index header ensure git keeps both folders, so a
# fresh clone is still recognized as a library.
# Globals:
#   myDir
# Arguments:
#   $1 - Library path
# Outputs:
#   One msgInfo line per file created, to STDERR
# Returns:
#   0 on success; halts (msgError) if folders can't be created
#######################################
function libraryEnsureFiles {
    local lib="$1"
    local errTxt src dest
    if ! errTxt="$(mkdir -p -- "$lib/images" "$lib/tags" 2>&1)"; then
        msgError "[!] Could not create library at: $lib
    $errTxt"
    fi
    local -A templates=(
        [sil.conf]=sil.conf
        [.gitignore]=gitignore
        [.gitattributes]=gitattributes
    )
    for dest in sil.conf .gitignore .gitattributes; do
        src="$myDir/templates/${templates[$dest]}"
        if [[ ! -e "$lib/$dest" ]]; then
            cp -- "$src" "$lib/$dest"
            msgInfo "  Added $dest"
        fi
    done
    if [[ ! -e "$lib/tags/.gitkeep" ]]; then
        : > "$lib/tags/.gitkeep"
        msgInfo "  Added tags/.gitkeep"
    fi
    srcLib "index"
    if [[ ! -e "$lib/images/fingerprints.txt" ]]; then
        indexWriteHeader "$lib/images/fingerprints.txt"
        msgInfo "  Added images/fingerprints.txt"
    fi
    if [[ ! -e "$lib/images/sources.txt" ]]; then
        sourcesWriteSorted "$lib/images/sources.txt" < /dev/null
        msgInfo "  Added images/sources.txt"
    fi
}

#######################################
# Create a new library with its standard folders and files.
# Arguments:
#   $1 - Library path
# Returns:
#   0 on success; halts (msgError) if folders can't be created
#######################################
function initLibrary {
    local lib="$1"
    msgInfo "Creating new library at: $lib"
    libraryEnsureFiles "$lib"
    msgInfo "Library settings can be changed in: $lib/sil.conf
    To share it, it can be made a git repository: git -C '$lib' init"
}

#######################################
# The library to use, by preference (no side effects):
#   1. LIBRARY from the command line
#   2. The library containing the current folder
#   3. LIBRARY from ~/.sil.conf
# A manifest may also name one (REQ-06), handled by parseManifest.
# Globals:
#   SIL_LIBRARY, PWD
# Outputs:
#   The chosen path, as given, to STDOUT
# Returns:
#   0 if one was found, 1 otherwise
#######################################
function chooseLibrary {
    local found
    if ! cliHasParam LIBRARY && found="$(findLibrary "$PWD")"; then
        printf '%s\n' "$found"
    elif [[ -n "${SIL_LIBRARY:-}" ]]; then
        printf '%s\n' "$SIL_LIBRARY"
    else
        return 1
    fi
}

#######################################
# Halt explaining how to name a library.
# Returns:
#   Does not return (msgError)
#######################################
function noLibraryError {
    msgError "[!] No image library found
    No LIBRARY was given, and the current folder is not inside a library
    (a folder containing 'images' and 'tags'). Either:
      * Run sil from inside a library folder
      * Give a library on the command line; it is created if needed:
          sil LIBRARY=~/Pictures/sil https://example.com/funny.jpg
      * Set LIBRARY at the top of a manifest, before any URIs
      * Set a default library in ~/.sil.conf:
          LIBRARY=~/Pictures/sil"
}

#######################################
# Use a library, creating it if it doesn't exist or is an empty folder,
# and set SIL_LIBRARY to its absolute path. A leading '~' is expanded,
# as conf files and manifests are not shell-expanded.
# Globals:
#   HOME; sets SIL_LIBRARY
# Arguments:
#   $1 - Library path
# Returns:
#   0 on success; halts (msgError) if it is a non-empty folder that isn't
#   a library, or not a folder
#######################################
function useLibrary {
    local lib="$1"
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

#######################################
# Decide which library to use (see chooseLibrary), creating it if
# needed, and set SIL_LIBRARY to its absolute path.
# Globals:
#   Sets SIL_LIBRARY
# Returns:
#   0 on success; halts (msgError) if no library can be determined, or
#   it can't be used (see useLibrary)
#######################################
function resolveLibrary {
    local lib
    lib="$(chooseLibrary)" || noLibraryError
    useLibrary "$lib"
}
