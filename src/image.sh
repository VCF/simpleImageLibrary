## Image inspection and fingerprinting - see REQ-05

## Supported formats, as reported by identify (%m), and the suffix used
## when storing them. Anything else is rejected, including SVG (shelved)
declare -gA _silImageSuffix=(
    [JPEG]=jpg
    [PNG]=png
    [GIF]=gif
    [WEBP]=webp
    [BMP]=bmp
    [TIFF]=tif
)

#######################################
# Determine an image's format from its content, using ImageMagick.
# ImageMagick also takes hints from the file suffix (eg trying to render
# '.html' files), so files being identified should have no suffix.
# Globals:
#   _silImageSuffix
# Arguments:
#   $1 - File path
# Outputs:
#   Format name to STDOUT (eg JPEG), when one is recognized
# Returns:
#   0 - supported image
#   1 - not an image
#   2 - supported image, but damaged (eg truncated)
#   3 - an image, but an unsupported format (eg SVG)
#######################################
function imageFormat {
    local format errTxt
    errTxt="$(identify -format '%m' "$1[0]" 2>&1 > /dev/null)"
    format="$(identify -format '%m' "$1[0]" 2> /dev/null)" || return 1
    [[ -n "$format" ]] || return 1
    printf '%s\n' "$format"
    [[ -n "${_silImageSuffix[$format]:-}" ]] || return 3
    [[ -z "$errTxt" ]] || return 2
}

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
# Test whether an image uses transparency.
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
# Compute an image's raw findimagedupes fingerprint: 256 bits, as 44
# base64 characters. The first frame is fingerprinted from a temporary
# copy stripped of profiles and metadata, as findimagedupes rejects some
# harmless flaws (eg "iCCP: known incorrect sRGB profile").
# Arguments:
#   $1 - Image path
# Outputs:
#   Fingerprint to STDOUT
# Returns:
#   0 on success, 1 if the image could not be fingerprinted
#######################################
function imageFingerprint {
    local tmp fp
    tmp="$(mktemp --suffix=.png)" || return 1
    if convert "$1[0]" -strip "$tmp" 2> /dev/null; then
        fp="$(findimagedupes --no-compare --verbosity=fingerprint -- "$tmp" \
            2> /dev/null | cut -d' ' -f1)"
    fi
    rm -f -- "$tmp"
    ## An empty result would otherwise hash to a valid-looking SHA1
    [[ "$fp" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s\n' "$fp"
}

#######################################
# SHA1 of a fingerprint string (with no trailing newline). Used as the
# image's stored file name; see REQ-05.
# Arguments:
#   $1 - Raw fingerprint (base64)
# Outputs:
#   40 character hex SHA1 to STDOUT
#######################################
function fingerprintHash {
    printf '%s' "$1" | sha1sum | cut -c1-40
}

#######################################
# Count the bits that differ between two raw fingerprints (0-256).
# Arguments:
#   $1, $2 - Raw fingerprints (base64)
# Outputs:
#   Bit count to STDOUT
# Returns:
#   0 on success, 1 if either fingerprint is malformed
#######################################
function fingerprintDistance {
    local ha hb
    ha="$(printf '%s' "$1" | base64 -d 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
    hb="$(printf '%s' "$2" | base64 -d 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
    (( ${#ha} == 64 && ${#hb} == 64 )) || return 1

    ## XOR 32 bits at a time, counting set bits
    local d=0 i x
    for (( i = 0; i < 64; i += 8 )); do
        x=$(( 0x${ha:i:8} ^ 0x${hb:i:8} ))
        while (( x )); do
            x=$(( x & (x - 1) ))
            d=$(( d + 1 ))
        done
    done
    printf '%s\n' "$d"
}

#######################################
# Test whether two raw fingerprints are similar at a percentage, using
# the same rule as findimagedupes: at most int(2.56 x (100 - pct)) bits
# may differ (90% allows 25, 95% allows 12).
# Arguments:
#   $1, $2 - Raw fingerprints (base64)
#   $3 - Similarity percentage (integer)
# Returns:
#   0 if similar, 1 if not or malformed
#######################################
function fingerprintsMatch {
    local d
    d="$(fingerprintDistance "$1" "$2")" || return 1
    (( d <= 256 * (100 - $3) / 100 ))
}
