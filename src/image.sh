## Image inspection and fingerprinting - see REQ-05

## Supported formats, as reported by identify (%m) or videoFormat, and
## the suffix used when storing them. Anything else is rejected, including
## SVG (shelved)
declare -gA _silImageSuffix=(
    [JPEG]=jpg
    [PNG]=png
    [GIF]=gif
    [WEBP]=webp
    [BMP]=bmp
    [TIFF]=tif
    [AVIF]=avif
    [MP4]=mp4
    [WEBM]=webm
    [MOV]=mov
)

## Supported video containers, by file(1) MIME type, and their SIL format
## names. ImageMagick has no video decoder, so ffmpeg handles these
declare -gA _silVideoMime=(
    [video/mp4]=MP4
    [video/x-m4v]=MP4
    [video/webm]=WEBM
    [video/quicktime]=MOV
)

## ffmpeg filter placing frames on a white background, so transparency
## doesn't depend on whatever color hides beneath it
declare -g _silFlattenVf="split[a][b];[a]drawbox=t=fill:c=white:replace=1[bg];[bg][b]overlay=format=auto,format=rgb24"

#######################################
# Test whether a format name, as from imageFormat, is a video.
# Globals:
#   _silVideoMime
# Arguments:
#   $1 - Format name (eg MP4)
# Returns:
#   0 if a video format, 1 otherwise
#######################################
function isVideoFormat {
    [[ -n "$1" && " ${_silVideoMime[*]} " == *" $1 "* ]]
}

#######################################
# Determine whether a file is a supported video, from its content: the
# container by file(1) MIME type, then a check with ffprobe that it holds
# a readable video stream. Only the container header is checked, so
# damage later in the file goes unnoticed until it is decoded.
# Globals:
#   _silVideoMime
# Arguments:
#   $1 - File path
# Outputs:
#   Format name to STDOUT (eg MP4), when the container is recognized
# Returns:
#   0 - supported video
#   1 - not a supported video container
#   2 - supported container, but no readable video stream (eg truncated)
#######################################
function videoFormat {
    local mime format
    mime="$(file -b --mime-type -- "$1" 2> /dev/null)"
    [[ -n "$mime" ]] || return 1
    format="${_silVideoMime[$mime]:-}"
    [[ -n "$format" ]] || return 1
    printf '%s\n' "$format"
    ## V (not v) skips cover art, which containers store as a video stream
    [[ -n "$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_type \
        -of csv=p=0 "file:$1" < /dev/null 2> /dev/null)" ]] || return 2
}

#######################################
# Determine an image's format from its content: videos with videoFormat,
# anything else with ImageMagick. ImageMagick also takes hints from the
# file suffix (eg trying to render '.html' files), so files being
# identified should have no suffix.
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
    local format errTxt rc=0
    format="$(videoFormat "$1")" || rc=$?
    if [[ -n "$format" ]]; then
        printf '%s\n' "$format"
        return "$rc"
    fi
    errTxt="$(identify -format '%m' "$1[0]" 2>&1 > /dev/null)"
    format="$(identify -format '%m' "$1[0]" 2> /dev/null)" || return 1
    [[ -n "$format" ]] || return 1
    printf '%s\n' "$format"
    [[ -n "${_silImageSuffix[$format]:-}" ]] || return 3
    [[ -z "$errTxt" ]] || return 2
}

#######################################
# List the display time of each frame of an animation or video, for the
# formats whose animations SIL handles. ffmpeg reads GIF, AVIF and videos
# (ImageMagick sees only the first frame of an animated AVIF); ImageMagick
# reads WebP (ffmpeg can't decode animated WebP). A WebP delay of 0 is shown
# by browsers as 0.1 seconds, as ffmpeg already does for GIF.
# ffmpeg and ffprobe are kept off STDIN throughout, as they would
# otherwise consume input meant for the caller (eg a while-read loop).
# Arguments:
#   $1 - Image path
#   $2 - Format, as from imageFormat
# Outputs:
#   One duration in seconds per frame to STDOUT; nothing for other
#   formats or unreadable files
#######################################
function frameDurations {
    if [[ "$2" == WEBP ]]; then
        identify -format '%T\n' "$1" 2> /dev/null \
            | awk '{ printf "%.2f\n", ($1 > 0 ? $1 : 10) / 100 }'
    elif [[ "$2" == GIF || "$2" == AVIF ]] || isVideoFormat "$2"; then
        ffprobe -v error -select_streams V:0 \
            -show_entries packet=duration_time -of csv=p=0 "file:$1" \
            < /dev/null 2> /dev/null
    fi
}

#######################################
# Count the frames in an image (>1 for animations).
# Arguments:
#   $1 - Image path
# Outputs:
#   Frame count to STDOUT (empty if unreadable)
#######################################
function imageFrames {
    local format n
    format="$(imageFormat "$1")"
    n="$(frameDurations "$1" "$format" | wc -l)"
    if (( n == 0 )); then
        n="$(identify -format '%n\n' "$1" 2> /dev/null | head -n 1)"
    fi
    printf '%s\n' "$n"
}

#######################################
# Test whether a file moves: a video, or an image of several frames.
# Arguments:
#   $1 - Image path
# Returns:
#   0 if animated, 1 if a still image
#######################################
function isAnimated {
    local frames
    isVideoFormat "$(imageFormat "$1")" && return 0
    frames="$(imageFrames "$1")"
    (( ${frames:-0} > 1 ))
}

#######################################
# Find an image's size in pixels. ffprobe reads videos, which ImageMagick
# can't, and a GIF's canvas, which its first frame may not fill.
# Arguments:
#   $1 - Image path
# Outputs:
#   Size to STDOUT as WIDTHxHEIGHT, eg 640x480
# Returns:
#   0 on success, 1 if the size can't be read
#######################################
function imageDimensions {
    local format dims
    format="$(imageFormat "$1")"
    if [[ "$format" == GIF ]] || isVideoFormat "$format"; then
        dims="$(ffprobe -v error -select_streams V:0 -show_entries stream=width,height \
            -of csv=p=0:s=x "file:$1" < /dev/null 2> /dev/null)"
    else
        dims="$(identify -format '%wx%h' "$1[0]" 2> /dev/null)"
    fi
    [[ "$dims" =~ ^[0-9]+x[0-9]+$ ]] || return 1
    printf '%s\n' "$dims"
}

#######################################
# Pick the frame on screen halfway through an animation. Animations
# often open on a blank or title frame, so this represents them better
# than the first frame. If no frame has a duration, the middle frame by
# count is used.
# Arguments:
#   STDIN - Frame durations, one per line (see frameDurations)
# Outputs:
#   Zero-based frame index to STDOUT
#######################################
function middleFrame {
    awk '{ d[NR - 1] = $1; total += $1 }
        END {
            if (total <= 0) { print int(NR / 2); exit }
            for (i = 0; i < NR; i++) {
                if (start + d[i] > total / 2) { print i; exit }
                start += d[i]
            }
            print NR - 1
        }'
}

#######################################
# Write the frame of an image that represents it for fingerprinting:
# for animations and videos, the middle frame (middleFrame) flattened
# onto white; otherwise the first frame. Profiles and metadata are stripped, as
# findimagedupes rejects some harmless flaws (eg "iCCP: known incorrect
# sRGB profile").
# Arguments:
#   $1 - Image path
#   $2 - Output PNG path
# Returns:
#   0 on success, 1 if the frame could not be extracted
#######################################
function fingerprintFrame {
    local format durations k
    format="$(imageFormat "$1")"
    durations="$(frameDurations "$1" "$format")"
    if ! isVideoFormat "$format" && (( $(grep -c . <<< "$durations") <= 1 )); then
        convert "$1[0]" -strip "$2" 2> /dev/null
        return
    fi
    k="$(middleFrame <<< "$durations")"
    if [[ "$format" == WEBP ]]; then
        convert "$1" -coalesce -background white -alpha remove miff:- 2> /dev/null \
            | convert "miff:-[$k]" -strip "$2" 2> /dev/null
    else
        ffmpeg -v error -y -i "file:$1" -map 0:V:0 -vf "$_silFlattenVf,select=eq(n\,$k)" \
            -fps_mode passthrough -frames:v 1 "file:$2" < /dev/null 2> /dev/null
    fi
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
# Test whether a video has sound.
# Arguments:
#   $1 - Video path
# Returns:
#   0 if it has an audio stream, 1 otherwise
#######################################
function hasAudio {
    [[ -n "$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "file:$1" < /dev/null 2> /dev/null)" ]]
}

#######################################
# Compute an image's raw findimagedupes fingerprint: 256 bits, as 44
# base64 characters, from the frame chosen by fingerprintFrame.
# Arguments:
#   $1 - Image path
# Outputs:
#   Fingerprint to STDOUT
# Returns:
#   0 on success, 1 if the image could not be fingerprinted
#######################################
function imageFingerprint {
    local tmp fp
    tmp="$(silMktemp .png)" || return 1
    if fingerprintFrame "$1" "$tmp"; then
        fp="$(findimagedupes --no-compare --verbosity=fingerprint -- "$tmp" \
            2> /dev/null | cut -d' ' -f1)"
    fi
    rm -f -- "$tmp"
    ## An empty result would otherwise hash to a valid-looking SHA1
    [[ "$fp" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s\n' "$fp"
}

#######################################
# An image's hash: the SHA1 of the file, used as its stored name (REQ-05).
# Arguments:
#   $1 - File path
# Outputs:
#   40 character hex SHA1 to STDOUT
# Returns:
#   0 on success, 1 if the file can't be read
#######################################
function fileHash {
    local sum
    sum="$(sha1sum -- "$1" 2> /dev/null)" || return 1
    printf '%s\n' "${sum:0:40}"
}

#######################################
# Convert a raw fingerprint from base64 to the 64 hexadecimal characters
# used in the fingerprint index.
# Arguments:
#   $1 - Raw fingerprint (base64)
# Outputs:
#   64 character hex string to STDOUT
# Returns:
#   0 on success, 1 if the fingerprint is malformed
#######################################
function fingerprintToHex {
    local hex
    hex="$(printf '%s' "$1" | base64 -d 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
    (( ${#hex} == 64 )) || return 1
    printf '%s\n' "$hex"
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
    ha="$(fingerprintToHex "$1")" || return 1
    hb="$(fingerprintToHex "$2")" || return 1

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
