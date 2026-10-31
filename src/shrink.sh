## Reduce image file size toward a target - see SHRINK in docs/parameters.md

## Similarity required between a shrunk image and its original. Fixed,
## independent of THRESHOLD (which governs library duplicates); catches
## conversions that ImageMagick has visibly damaged
declare -g _silShrinkVerify=90

#######################################
# Count the frames in an image (>1 for animations).
# Arguments:
#   $1 - Image path
# Outputs:
#   Frame count to STDOUT (empty if unreadable)
#######################################
function imageFrames {
    identify -format '%n\n' "$1" 2> /dev/null | head -n 1
}

#######################################
# Test whether an image uses transparency, which JPEG cannot store.
# Arguments:
#   $1 - Image path
# Returns:
#   0 if any pixel is not fully opaque, 1 otherwise
#######################################
function hasTransparency {
    local opaque
    opaque="$(identify -format '%[opaque]' "$1[0]" 2> /dev/null)"
    [[ "${opaque,,}" == false ]]
}

#######################################
# Test whether two images have matching fingerprints at the shrink
# verification threshold.
# Globals:
#   _silShrinkVerify
# Arguments:
#   $1, $2 - Image paths
# Returns:
#   0 if they match, 1 otherwise
#######################################
function imagesMatch {
    [[ -n "$(findimagedupes --threshold="${_silShrinkVerify}%" -- \
        "$1" "$2" 2> /dev/null)" ]]
}

#######################################
# Re-encode an image as JPEG of about SIL_SHRINK bytes, then check the
# result saves enough and still matches. Helper for shrinkImage, which
# handles cleanup.
# Globals:
#   SIL_SHRINK, SIL_SHRINKMINSAVE, _silShrinkVerify
# Arguments:
#   $1 - Original image path
#   $2 - Reference path: the original, or a path at which to write a
#        flattened copy (FLATTEN). The result is verified against this,
#        since flattening is an intended change
#   $3 - Output path for the shrunk JPEG
#   $4 - Size of the original, in bytes
# Outputs:
#   Progress messages to STDERR
# Returns:
#   0 if the shrunk JPEG should be kept, 1 otherwise
#######################################
function encodeShrunk {
    local src="$1" ref="$2" out="$3" srcBytes="$4"
    local errTxt
    if [[ "$ref" != "$src" ]]; then
        if ! errTxt="$(convert "${src}[0]" -background white -flatten "$ref" 2>&1)"; then
            msgWarn "[!] ImageMagick could not flatten the image, keeping original
    $errTxt"
            return 1
        fi
        msgInfo "  Flattened transparency onto white (FLATTEN)"
    fi

    if ! errTxt="$(convert "${ref}[0]" -define "jpeg:extent=$SIL_SHRINK" "$out" 2>&1)" \
        || [[ ! -s "$out" ]]; then
        msgWarn "[!] ImageMagick could not shrink the image, keeping original
    $errTxt"
        return 1
    fi

    local outBytes saved
    outBytes="$(stat -c %s -- "$out")"
    saved=$(( 100 * (srcBytes - outBytes) / srcBytes ))
    if (( saved < ${SIL_SHRINKMINSAVE:-25} )); then
        msgInfo "  Not shrinking: only saved ${saved}%, SHRINKMINSAVE is ${SIL_SHRINKMINSAVE}%"
        return 1
    fi
    if ! imagesMatch "$ref" "$out"; then
        msgWarn "[!] Shrunk image no longer matches the original at ${_silShrinkVerify}% similarity
    ImageMagick may have damaged it during conversion. Keeping original"
        return 1
    fi

    msgInfo "  Shrunk $(humanSize "$srcBytes") -> $(humanSize "$outBytes") (saved ${saved}%)"
}

#######################################
# Shrink an image to about SIL_SHRINK bytes by re-encoding as JPEG
# (ImageMagick jpeg:extent). The original is kept if shrinking is off,
# not triggered, not possible, saves too little, or changes the image.
# Transparent images are only shrunk with FLATTEN, which places them on
# a white background first.
# A kept shrunk copy is written beside the original as <base>.shrunk.jpg;
# the original is never modified.
# Globals:
#   SIL_SHRINK, SIL_SHRINKTRIGGER, SIL_SHRINKMINSAVE, SIL_FLATTEN
# Arguments:
#   $1 - Image path
#   $2 - Name of the variable to receive the path to keep (the shrunk
#        copy or the original). A variable rather than STDOUT so that
#        missing tools can halt (msgError) instead of dying in a subshell
# Outputs:
#   Progress messages to STDERR
# Returns:
#   0; halts (msgError) if ImageMagick or findimagedupes are missing
#######################################
function shrinkImage {
    local src="$1" resultVar="$2"
    local target="${SIL_SHRINK:-0}"
    printf -v "$resultVar" '%s' "$src"
    (( target > 0 )) || return 0

    local srcBytes trigger
    srcBytes="$(stat -c %s -- "$src")"
    trigger="$(awk -v t="$target" -v f="${SIL_SHRINKTRIGGER:-2}" \
        'BEGIN { printf "%d", t * f }')"
    if (( srcBytes < trigger )); then
        msgInfo "  Not shrinking: $(humanSize "$srcBytes") is under the trigger of $(humanSize "$trigger")"
        return 0
    fi

    requireTool convert imagemagick "shrink images (SHRINK parameter)"
    requireTool findimagedupes findimagedupes \
        "check shrunk images still match their originals"

    if (( $(imageFrames "$src") > 1 )); then
        msgInfo "  Not shrinking: animated images are left unchanged"
        return 0
    fi

    local ref="$src"
    if hasTransparency "$src"; then
        if ! flagIsSet FLATTEN; then
            msgInfo "  Not shrinking: image has transparency, which JPEG would lose
    Set FLATTEN to shrink it onto a white background instead"
            return 0
        fi
        ref="${src%.*}.flat.png"
    fi

    local out="${src%.*}.shrunk.jpg"
    if encodeShrunk "$src" "$ref" "$out" "$srcBytes"; then
        printf -v "$resultVar" '%s' "$out"
    else
        rm -f -- "$out"
    fi
    [[ "$ref" != "$src" ]] && rm -f -- "$ref"
    return 0
}
