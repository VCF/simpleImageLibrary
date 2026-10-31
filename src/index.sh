## Stored images and the fingerprint index - see REQ-05

srcLib "image"

## A stored image's file name: <hash>.<suffix>
declare -g _silStoredNameRe='^([0-9a-f]{40})\.[a-z]+$'

#######################################
# Path of the library's fingerprint index.
# Globals:
#   SIL_LIBRARY
# Outputs:
#   Path to STDOUT
#######################################
function indexFile {
    printf '%s\n' "$SIL_LIBRARY/images/fingerprints.txt"
}

#######################################
# Write the explanatory header that starts every fingerprint index.
# Arguments:
#   $1 - Path to write to (overwritten)
#######################################
function indexWriteHeader {
    cat > "$1" << 'EOF'
# SIL fingerprint index - see REQ-05 in docs/requirements.md
# Each line: <image hash> <fingerprint as 64 hexadecimal characters>
# Regenerate from the stored images with: sil REBUILD
EOF
}

#######################################
# Path at which an image with a given hash and suffix is stored.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Image hash
#   $2 - Suffix, eg jpg
# Outputs:
#   Path to STDOUT
#######################################
function storedImagePath {
    printf '%s\n' "$SIL_LIBRARY/images/${1:0:2}/${1:2:2}/$1.$2"
}

#######################################
# Find a stored image by its hash, whatever its suffix.
# Globals:
#   SIL_LIBRARY
# Arguments:
#   $1 - Image hash
# Outputs:
#   Path to STDOUT
# Returns:
#   0 if found, 1 otherwise
#######################################
function findStoredImage {
    local hash="${1,,}" f
    [[ "$hash" =~ ^[0-9a-f]{40}$ ]] || return 1
    for f in "$SIL_LIBRARY/images/${hash:0:2}/${hash:2:2}/$hash".*; do
        if [[ -f "$f" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

#######################################
# Test whether an image hash is in the fingerprint index.
# Arguments:
#   $1 - Image hash
# Returns:
#   0 if present, 1 otherwise
#######################################
function indexHas {
    grep -q "^$1 " "$(indexFile)" 2> /dev/null
}

#######################################
# Write a fingerprint index: the header, then entry lines sorted by hash
# with repeats removed. Sorting (in the C locale, so it is identical on
# every machine) keeps git diffs and merges small (REQ-10).
# Arguments:
#   $1 - Path to write to (overwritten)
# Inputs:
#   Entry lines on STDIN; comment lines are dropped
#######################################
function indexWriteSorted {
    indexWriteHeader "$1"
    grep -v '^#' | LC_ALL=C sort -u >> "$1"
}

#######################################
# Add an image to the fingerprint index, unless already present, keeping
# the index sorted.
# Arguments:
#   $1 - Image hash
#   $2 - Raw fingerprint (base64)
# Returns:
#   0 on success, 1 if the fingerprint is malformed or the index can't
#   be written
#######################################
function indexAdd {
    local index hex tmp
    index="$(indexFile)"
    hex="$(fingerprintToHex "$2")" || return 1
    indexHas "$1" && return 0
    tmp="$(silMktemp)" || return 1
    { [[ -f "$index" ]] && cat -- "$index"; printf '%s %s\n' "$1" "$hex"; } \
        | indexWriteSorted "$tmp"
    mv -- "$tmp" "$index"
}

#######################################
# Find indexed images similar to a fingerprint (see REQ-05 for the rule).
# Arguments:
#   $1 - Raw fingerprint (base64)
#   $2 - Similarity percentage, eg $SIL_THRESHOLD
# Outputs:
#   One "<differing bits> <hash>" line per match to STDOUT, closest
#   first; nothing if there are no matches
# Returns:
#   0 on success, 1 if the fingerprint is malformed
#######################################
function indexMatch {
    local index hex
    index="$(indexFile)"
    hex="$(fingerprintToHex "$1")" || return 1
    [[ -f "$index" ]] || return 0
    awk -v q="$hex" -v maxbits="$(( 256 * (100 - $2) / 100 ))" '
        BEGIN {
            ## pop["xy"]: bits differing between hex digits x and y
            h = "0123456789abcdef"
            for (i = 0; i < 16; i++) for (j = 0; j < 16; j++) {
                x = i; y = j; c = 0
                for (b = 0; b < 4; b++) {
                    if (x % 2 != y % 2) c++
                    x = int(x / 2); y = int(y / 2)
                }
                pop[substr(h, i + 1, 1) substr(h, j + 1, 1)] = c
            }
        }
        /^#/ || NF != 2 || length($2) != 64 { next }
        {
            d = 0
            for (k = 1; k <= 64 && d <= maxbits; k++)
                d += pop[substr(q, k, 1) substr($2, k, 1)]
            if (d <= maxbits) print d, $1
        }' "$index" | sort -n -k1,1
}

#######################################
# Store an image file in the library under its hash, and add it to the
# fingerprint index. Does not check for similar images; callers do that
# first with indexMatch.
# Arguments:
#   $1 - Image file (already shrunk etc; stored exactly as is)
#   $2 - Name of the variable to receive the image hash
# Returns:
#   0 on success; 1 if not a supported, readable image, or it can't be
#   written to the library
#######################################
function storeImage {
    local _src="$1" _resultVar="$2"
    local _format _hash _fp _dest
    _format="$(imageFormat "$_src")" || return 1
    _hash="$(fileHash "$_src")" || return 1
    _fp="$(imageFingerprint "$_src")" || return 1
    _dest="$(storedImagePath "$_hash" "${_silImageSuffix[$_format]}")"
    if [[ ! -f "$_dest" ]]; then
        mkdir -p -- "$(dirname -- "$_dest")" && cp -- "$_src" "$_dest" || return 1
    fi
    indexAdd "$_hash" "$_fp" || return 1
    printf -v "$_resultVar" '%s' "$_hash"
}
