## Library maintenance: CHECK and REBUILD - see REQ-09

srcLib "index"

#######################################
# List every file under the library's images folder, except the index.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   One path per line to STDOUT, sorted
#######################################
function listImageFiles {
    find "$SIL_LIBRARY/images" -type f ! -path "$(indexFile)" | sort
}

#######################################
# Regenerate the fingerprint index from the stored images. The new index
# replaces the old one only once complete.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe
# Outputs:
#   Progress and problems to STDERR
# Returns:
#   0 on success, 1 if any stored image could not be fingerprinted;
#   halts (msgError) if needed tools are missing
#######################################
function indexRebuild {
    requireTool convert imagemagick "fingerprint stored images"
    requireTool findimagedupes findimagedupes "fingerprint stored images"

    local index new f name hash fp hex
    local count=0 failed=0
    index="$(indexFile)"
    new="$(mktemp "$index.XXXXXX")" || msgError "[!] Could not write to: $SIL_LIBRARY/images"
    indexWriteHeader "$new"

    msgInfo "Rebuilding fingerprint index: $index"
    while IFS= read -r f; do
        name="$(basename -- "$f")"
        ## Unexpected files are reported by CHECK, not indexed
        [[ "$name" =~ $_silStoredNameRe ]] || continue
        hash="${BASH_REMATCH[1]}"
        if ! fp="$(imageFingerprint "$f")" || ! hex="$(fingerprintToHex "$fp")"; then
            msgWarn "[!] Could not fingerprint, left out of the index: ${f#"$SIL_LIBRARY"/}"
            failed=$(( failed + 1 ))
            continue
        fi
        printf '%s %s\n' "$hash" "$hex" >> "$new"
        count=$(( count + 1 ))
        (( count % 100 == 0 )) && msgInfo "  $count images fingerprinted"
    done < <(listImageFiles)

    mv -- "$new" "$index"
    msgInfo "Fingerprint index rebuilt: $count images"
    (( failed == 0 ))
}

#######################################
# Check the library for problems (REQ-09), reporting each with a fix.
# Changes nothing.
# Globals:
#   SIL_LIBRARY, _silStoredNameRe
# Outputs:
#   Problems and a summary to STDERR
# Returns:
#   0 if no problems were found, 1 otherwise
#######################################
function libraryCheck {
    local problems=0 indexProblems=0
    local -A stored=() indexed=()
    local f rel name hash dir expected actual
    local index line lineNum=0

    msgInfo "Checking library: $SIL_LIBRARY"

    while IFS= read -r f; do
        rel="${f#"$SIL_LIBRARY"/}"
        name="$(basename -- "$f")"
        if [[ ! "$name" =~ $_silStoredNameRe ]]; then
            msgWarn "[!] Unexpected file in images: $rel
    Fix: move it out of images; to add it to the library, use sil"
            problems=$(( problems + 1 ))
            continue
        fi
        hash="${BASH_REMATCH[1]}"
        expected="images/${hash:0:2}/${hash:2:2}"
        dir="$(dirname -- "$rel")"
        if [[ "$dir" != "$expected" ]]; then
            msgWarn "[!] Stored in the wrong folder: $rel
    Fix: move it to $expected/"
            problems=$(( problems + 1 ))
        fi
        actual="$(fileHash "$f")"
        if [[ "$actual" != "$hash" ]]; then
            msgWarn "[!] File does not match its name, it may be damaged or edited: $rel
    Its sha1sum is $actual
    Fix: restore it from a backup, or remove it and add the image again"
            problems=$(( problems + 1 ))
        fi
        if [[ -n "${stored[$hash]:-}" ]]; then
            msgWarn "[!] Image stored twice: ${stored[$hash]} and $rel
    Fix: remove one of them"
            problems=$(( problems + 1 ))
        fi
        stored[$hash]="$rel"
    done < <(listImageFiles)

    index="$(indexFile)"
    if [[ -f "$index" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineNum=$(( lineNum + 1 ))
            [[ "$line" == \#* ]] && continue
            if [[ ! "$line" =~ ^([0-9a-f]{40})\ [0-9a-f]{64}$ ]]; then
                msgWarn "[!] Malformed fingerprint index line $lineNum: $line"
                indexProblems=$(( indexProblems + 1 ))
                continue
            fi
            hash="${BASH_REMATCH[1]}"
            if [[ -n "${indexed[$hash]:-}" ]]; then
                msgWarn "[!] Image listed twice in fingerprint index: $hash"
                indexProblems=$(( indexProblems + 1 ))
            elif [[ -z "${stored[$hash]:-}" ]]; then
                msgWarn "[!] Fingerprint index lists an image that isn't stored: $hash"
                indexProblems=$(( indexProblems + 1 ))
            fi
            indexed[$hash]=1
        done < "$index"
    fi
    for hash in "${!stored[@]}"; do
        if [[ -z "${indexed[$hash]:-}" ]]; then
            msgWarn "[!] Not in fingerprint index: ${stored[$hash]}"
            indexProblems=$(( indexProblems + 1 ))
        fi
    done
    if (( indexProblems )); then
        msgWarn "    Fix for fingerprint index problems: sil REBUILD"
        problems=$(( problems + indexProblems ))
    fi

    while IFS= read -r f; do
        msgWarn "[!] Broken tag link: ${f#"$SIL_LIBRARY"/} -> $(readlink -- "$f")
    Fix: remove the link"
        problems=$(( problems + 1 ))
    done < <(find "$SIL_LIBRARY/tags" -xtype l 2> /dev/null | sort)

    if (( problems )); then
        msgWarn "[!] $problems problem(s) found in ${#stored[@]} stored images"
        return 1
    fi
    msgInfo "No problems found in ${#stored[@]} stored images"
}
