## Library location, creation and locking - see LIBRARY in docs/parameters.md
## and REQ-12

## Libraries locked by this run: absolute path -> open lock file descriptor
declare -gA _silLibraryLocks=()

## Both live in the library's .tmp folder, which git already ignores. The lock
## file is only a target for flock; who holds it is noted separately, as
## opening and closing the locked file to rewrite it could drop an NFS lock
declare -g _silLockFile="library.lock" _silLockOwnerFile="library.owner"

## Status from flock when another process holds the lock
declare -g _silLockBusy=75

#######################################
# Describe the process holding a library's lock, for the refusal message.
# Arguments:
#   $1 - Library path
# Outputs:
#   Indented lines to STDOUT: who holds it, and what the user can do
#######################################
function lockHolderText {
    local lib="$1" pid="" host="" since="" cmdLine=""
    {
        IFS= read -r pid && IFS= read -r host && IFS= read -r since && IFS= read -r cmdLine
    } 2> /dev/null < "$lib/.tmp/$_silLockOwnerFile" || :
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        printf '    Wait for the other sil to finish, then run this again\n'
        return 0
    fi
    printf '    Held by PID %s on %s since %s: %s\n' "$pid" "$host" "$since" "$cmdLine"
    if [[ "$host" == "$(uname -n)" && -d "/proc/$pid" ]]; then
        printf '    Let it finish or stop it, then run this again\n'
        return 0
    fi
    if [[ "$host" == "$(uname -n)" ]]; then
        printf '    That process has ended, so a program it started is probably still\n'
        printf '    finishing. The lock is freed when that program exits\n'
    else
        printf '    SIL cannot tell from here if that process is still running\n'
    fi
    printf "    Only if certain nothing is using this library, delete the lock:\n"
    printf "      rm '%s'\n" "$lib/.tmp/$_silLockFile"
}

#######################################
# Remove temporary files left in a library's .tmp folder by a run that was
# killed. Only safe while holding the library's lock.
# Arguments:
#   $1 - Library path
# Outputs:
#   How many were removed, if any, to STDERR
#######################################
function clearLeftoverTemp {
    local dir="$1/.tmp" count
    count="$(find "$dir" -mindepth 1 -maxdepth 1 -name 'sil.*' -printf '.' | wc -c)"
    (( count )) || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -name 'sil.*' -exec rm -rf -- {} +
    msgInfo "  Removed $count temporary file(s) left by an interrupted run"
}

#######################################
# Lock a library for the rest of this run, or refuse if another process
# has it (REQ-12). The kernel holds the lock on an open file descriptor, so
# it ends with the process however that happens, and a leftover lock file
# means nothing. Locks are kept until exit, even after moving to another
# library, so a manifest can always return to the library it started from.
# Globals:
#   _silCommandLine; updates _silLibraryLocks; clears _silHaltHook on refusal
# Arguments:
#   $1 - Absolute library path
# Returns:
#   0 once locked; halts (msgError) if locked elsewhere, or locking fails
#######################################
function lockLibrary {
    local lib="$1" lockPath fd errTxt rc
    [[ -n "${_silLibraryLocks[$lib]:-}" ]] && return 0
    requireTool flock util-linux "keep two runs from using a library at once"
    lockPath="$lib/.tmp/$_silLockFile"
    if ! mkdir -p -- "$lib/.tmp" 2> /dev/null || ! { exec {fd}>> "$lockPath"; } 2> /dev/null; then
        msgError "[!] Could not open the library's lock file: $lockPath
    SIL needs write access to the library, even just to check it"
    fi
    errTxt="$(flock -n -E "$_silLockBusy" "$fd" 2>&1)"
    rc=$?
    if (( rc == _silLockBusy )); then
        ## Any logs beside a manifest are not this run's to finish: they may
        ## belong to the very run holding the lock. No URI can have been
        ## processed yet, as LIBRARY must precede them
        _silHaltHook=""
        msgError "[!] Library is in use by another sil: $lib
$(lockHolderText "$lib")"
    elif (( rc != 0 )); then
        msgError "[!] Could not lock the library: $lib
    $errTxt
    On NFS, the mount must support locks (no 'nolock' option, and rpc.statd
    running for NFSv3)"
    fi
    _silLibraryLocks[$lib]="$fd"
    {
        printf '%s\n%s\n%s\n%s\n' "$$" "$(uname -n)" "$(date '+%Y-%m-%d %H:%M:%S')" \
            "${_silCommandLine:-sil}" > "$lib/.tmp/$_silLockOwnerFile"
    } 2> /dev/null || :
    clearLeftoverTemp "$lib"
}

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
# A manifest may also name or be inside one (REQ-06), handled by
# parseManifest.
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
# lock it for this run, and set SIL_LIBRARY to its absolute path. A leading
# '~' is expanded, as conf files and manifests are not shell-expanded.
# Globals:
#   HOME; sets SIL_LIBRARY
# Arguments:
#   $1 - Library path
# Returns:
#   0 on success; halts (msgError) if it is a non-empty folder that isn't
#   a library, not a folder, or locked by another process
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
    lockLibrary "$lib"
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
