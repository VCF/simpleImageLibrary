## Reduce image file size - see SHRINK and SHRINKVID in docs/parameters.md

srcLib "image"

## Similarity required between a shrunk image and its original. Fixed,
## independent of THRESHOLD (which governs library duplicates); catches
## conversions that ImageMagick has visibly damaged
declare -g _silShrinkVerify=95

## As _silShrinkVerify, for animations (SHRINKVID). Lower, as one frame of
## a detailed animation varies more under AV1: neighboring frames of a
## sample animation differed from their originals by 5-15 bits
declare -g _silShrinkVidVerify=90

## Set when shrinking is rejected (SHRINKFAIL): why, for the outcome
declare -g _silShrinkFailDetail=""

## Set by shrinkImage: what shrinking did, or why it left the image as
## is, for the outcome line. Empty when shrinking is off
declare -g _silShrinkNote=""

## AV1 quality (crf, lower is better) for each SHRINKVID level. Measured
## on seven sample animations (19 KB - 100 MB), the AVIF was 4-60% of the
## original GIF at HIGH, 2-45% at MEDIUM and 1-30% at LOW. Even LOW kept
## very good fidelity to the original
declare -gA _silShrinkVidCrf=(
    [HIGH]=20
    [MEDIUM]=30
    [LOW]=40
)

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
#   Warnings to STDERR
# Returns:
#   0 if the shrunk JPEG should be kept; 1 to keep the original instead;
#   2 if the shrunk JPEG failed its check (see _silShrinkFailDetail), so
#   the image should not be added
#######################################
function encodeShrunk {
    local src="$1" ref="$2" out="$3" srcBytes="$4"
    local errTxt
    if [[ "$ref" != "$src" ]]; then
        msgStatus "  Flattening transparency onto white"
        if ! errTxt="$(convert "${src}[0]" -background white -flatten "$ref" 2>&1)"; then
            msgWarn "[!] ImageMagick could not flatten the image, keeping original
    $errTxt"
            return 1
        fi
    fi

    msgStatus "  Shrinking $(humanSize "$srcBytes") to JPEG"
    if ! errTxt="$(convert "${ref}[0]" -define "jpeg:extent=$SIL_SHRINK" "$out" 2>&1)" \
        || [[ ! -s "$out" ]]; then
        msgWarn "[!] ImageMagick could not shrink the image, keeping original
    $errTxt"
        return 1
    fi

    verifyShrunk "$ref" "$out" "$srcBytes" SHRINK "$_silShrinkVerify" || return
    [[ "$ref" != "$src" ]] && _silShrinkNote+=", flattened onto white"
    return 0
}

#######################################
# Check a shrunk copy saves at least SHRINKMINSAVE and still matches its
# reference.
# Globals:
#   SIL_SHRINKMINSAVE, _silParamDefault; sets _silShrinkNote,
#   _silShrinkFailDetail
# Arguments:
#   $1 - Reference image the shrunk copy should match
#   $2 - Shrunk copy
#   $3 - Size of the original, in bytes
#   $4 - Parameter that controls this shrink (SHRINK or SHRINKVID), for
#        advice when the check fails
#   $5 - Similarity percentage the copy must match at
# Outputs:
#   A warning to STDERR if the copy fails its check
# Returns:
#   0 if the shrunk copy should be kept; 1 to keep the original instead;
#   2 if the shrunk copy failed its check (see _silShrinkFailDetail)
#######################################
function verifyShrunk {
    local ref="$1" out="$2" srcBytes="$3" param="$4" pct="$5"
    local outBytes saved
    outBytes="$(stat -c %s -- "$out")"
    saved=$(( 100 * (srcBytes - outBytes) / srcBytes ))
    if (( saved < ${SIL_SHRINKMINSAVE:-25} )); then
        _silShrinkNote="As is (saves only ${saved}% < SHRINKMINSAVE ${SIL_SHRINKMINSAVE:-25}%)"
        return 1
    fi
    local fpRef fpOut bits
    msgStatus "  Checking the shrunk copy still matches"
    if ! fpRef="$(imageFingerprint "$ref")" || ! fpOut="$(imageFingerprint "$out")"; then
        _silShrinkFailDetail="Shrunk copy could not be fingerprinted to check it"
        return 2
    fi
    if ! fingerprintsMatch "$fpRef" "$fpOut" "$pct"; then
        bits="$(fingerprintDistance "$fpRef" "$fpOut")"
        _silShrinkFailDetail="Shrunk copy differs from original ($bits bits); try another $param"
        msgWarn "[!] Shrunk image no longer matches the original at ${pct}% similarity
    ($bits of 256 fingerprint bits differ); the conversion may have damaged it.
    Not added; retry with a different $param, or $param=${_silParamDefault[$param]}"
        return 2
    fi

    _silShrinkNote="$(humanSize "$srcBytes") -> $(humanSize "$outBytes")"
    [[ "$param" == SHRINKVID ]] && _silShrinkNote+=" AVIF"
    _silShrinkNote+=" (saved ${saved}%)"
}

#######################################
# Re-encode an animated GIF or WebP as animated AVIF (AV1), at the
# SHRINKVID quality level, then check the result with verifyShrunk.
# Frames are placed on white, as AVIF is written without transparency.
# Helper for shrinkAnimation, which handles cleanup.
# Globals:
#   SIL_SHRINKVID, _silShrinkVidCrf, _silShrinkVidVerify, _silFlattenVf
# Arguments:
#   $1 - Original animation path
#   $2 - Its format: GIF or WEBP
#   $3 - Output path for the AVIF
#   $4 - Size of the original, in bytes
# Outputs:
#   Warnings to STDERR
# Returns:
#   As verifyShrunk: 0 keep the AVIF, 1 keep the original, 2 the AVIF
#   failed its check
#######################################
function encodeAnimation {
    local src="$1" format="$2" out="$3" srcBytes="$4"
    local durations frames="" errTxt rc=0
    local -a input
    durations="$(frameDurations "$src" "$format")"

    if [[ "$format" == WEBP ]]; then
        msgStatus "  Extracting animation frames"
        ## ffmpeg can't decode animated WebP: ImageMagick writes the frames,
        ## and an ffconcat list gives ffmpeg each frame's duration. A frame
        ## rate of 100 keeps WebP's centisecond times exact. ffmpeg gives
        ## the last listed frame 0.01 seconds whatever its duration, so the
        ## last frame is listed twice: the AVIF gains an unseen 0.01 second
        ## frame at its end
        if ! frames="$(mktemp -d --tmpdir="$(silTempDir)" sil.XXXXXX)" \
            || ! convert "$src" -coalesce "$frames/f%05d.png" 2> /dev/null; then
            [[ -n "$frames" ]] && rm -rf -- "$frames"
            msgWarn "[!] ImageMagick could not read the animation frames, keeping original"
            return 1
        fi
        awk -v d="$frames" 'BEGIN { print "ffconcat version 1.0" }
            { printf "file %s/f%05d.png\noption framerate 100\nduration %s\n",
                d, NR - 1, $1 }
            END { printf "file %s/f%05d.png\noption framerate 100\n", d, NR - 1 }' \
            <<< "$durations" > "$frames/list.txt"
        input=(-f concat -safe 0 -i "file:$frames/list.txt")
    else
        input=(-i "file:$src")
    fi

    msgStatus "  Shrinking $(humanSize "$srcBytes") animation to AVIF (SHRINKVID=$SIL_SHRINKVID)"
    errTxt="$(ffmpeg -v error -y "${input[@]}" -fps_mode passthrough \
        -vf "$_silFlattenVf,pad=ceil(iw/2)*2:ceil(ih/2)*2" \
        -c:v libaom-av1 -crf "${_silShrinkVidCrf[$SIL_SHRINKVID]}" -b:v 0 \
        -cpu-used 6 -row-mt 1 -pix_fmt yuv420p -loop 0 \
        -f avif "file:$out" 2>&1 < /dev/null)" || rc=$?
    [[ -n "$frames" ]] && rm -rf -- "$frames"
    if (( rc )) || [[ ! -s "$out" ]]; then
        msgWarn "[!] ffmpeg could not shrink the animation, keeping original
    $errTxt"
        return 1
    fi

    verifyShrunk "$src" "$out" "$srcBytes" SHRINKVID "$_silShrinkVidVerify"
}

#######################################
# Shrink an animated GIF or WebP by re-encoding it as animated AVIF
# (SHRINKVID). Other animations, eg already AVIF, are left unchanged.
# Transparency is lost (placed on white), with a warning.
# Globals:
#   SIL_SHRINKVID; sets _silShrinkNote
# Arguments:
#   $1 - Animation path
#   $2 - Name of the variable to receive the path to keep, as for
#        shrinkImage
# Outputs:
#   Warnings to STDERR
# Returns:
#   As shrinkImage; halts (msgError) if ffmpeg is missing
#######################################
function shrinkAnimation {
    local _src="$1" _resultVar="$2"
    if [[ "${SIL_SHRINKVID:-OFF}" == OFF ]]; then
        _silShrinkNote="As is (animated; SHRINKVID is off)"
        return 0
    fi
    local _format
    _format="$(imageFormat "$_src")"
    if [[ "$_format" != GIF && "$_format" != WEBP ]]; then
        _silShrinkNote="As is (animated $_format)"
        return 0
    fi
    requireTool ffmpeg ffmpeg "shrink animations (SHRINKVID parameter)"
    if hasTransparency "$_src"; then
        msgWarn "[!] Animation has transparency, which AVIF will lose: placing it on white"
    fi

    local _out _rc=0
    _out="$(silMktemp .avif)" || return 0
    _silShrinkFailDetail=""
    encodeAnimation "$_src" "$_format" "$_out" "$(stat -c %s -- "$_src")" || _rc=$?
    if (( _rc == 0 )); then
        printf -v "$_resultVar" '%s' "$_out"
    else
        rm -f -- "$_out"
    fi
    (( _rc == 2 )) && return 2
    return 0
}

#######################################
# Shrink an image. Animations go to shrinkAnimation (SHRINKVID); other
# images are re-encoded as JPEG of about SIL_SHRINK bytes (ImageMagick
# jpeg:extent). The original is kept if shrinking is off, not triggered,
# not possible, saves too little, or changes the image.
# Transparent images are only shrunk to JPEG with FLATTEN, which places
# them on a white background first.
# A kept shrunk copy is a new temporary file (silMktemp) that the caller
# removes when done; the original is never modified.
# Globals:
#   SIL_SHRINK, SIL_SHRINKVID, SIL_SHRINKTRIGGER, SIL_SHRINKMINSAVE,
#   SIL_FLATTEN; sets _silShrinkNote
# Arguments:
#   $1 - Image path
#   $2 - Name of the variable to receive the path to keep (the shrunk
#        copy or the original). A variable rather than STDOUT so that
#        missing tools can halt (msgError) instead of dying in a subshell
# Outputs:
#   Warnings to STDERR
# Returns:
#   0 normally, with the path to keep set; 2 if the shrunk copy failed its
#   check (see _silShrinkFailDetail), so the image should not be added;
#   halts (msgError) if ImageMagick, findimagedupes or (for animations)
#   ffmpeg are missing
#######################################
function shrinkImage {
    local _src="$1" _resultVar="$2"
    local _target="${SIL_SHRINK:-0}"
    _silShrinkNote=""
    printf -v "$_resultVar" '%s' "$_src"
    (( _target > 0 )) || [[ "${SIL_SHRINKVID:-OFF}" != OFF ]] || return 0

    requireTool convert imagemagick "shrink images (SHRINK parameter)"
    requireTool findimagedupes findimagedupes \
        "check shrunk images still match their originals"

    if (( $(imageFrames "$_src") > 1 )); then
        shrinkAnimation "$_src" "$_resultVar"
        return
    fi
    (( _target > 0 )) || return 0

    local _srcBytes _trigger
    _srcBytes="$(stat -c %s -- "$_src")"
    _trigger="$(awk -v t="$_target" -v f="${SIL_SHRINKTRIGGER:-2}" \
        'BEGIN { printf "%d", t * f }')"
    if (( _srcBytes < _trigger )); then
        _silShrinkNote="As is ($(humanSize "$_srcBytes") < $(humanSize "$_trigger"))"
        return 0
    fi

    local _ref="$_src"
    if hasTransparency "$_src"; then
        if ! flagIsSet FLATTEN; then
            _silShrinkNote="As is (transparent; set FLATTEN to shrink onto white)"
            return 0
        fi
        _ref="$(silMktemp .png)" || return 0
    fi

    local _out
    if ! _out="$(silMktemp .jpg)"; then
        [[ "$_ref" != "$_src" ]] && rm -f -- "$_ref"
        return 0
    fi
    local _rc=0
    _silShrinkFailDetail=""
    encodeShrunk "$_src" "$_ref" "$_out" "$_srcBytes" || _rc=$?
    if (( _rc == 0 )); then
        printf -v "$_resultVar" '%s' "$_out"
    else
        rm -f -- "$_out"
    fi
    [[ "$_ref" != "$_src" ]] && rm -f -- "$_ref"
    (( _rc == 2 )) && return 2
    return 0
}
