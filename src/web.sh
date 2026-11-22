## WebSIL: a web page for browsing a library - see BUILDWEB in
## docs/parameters.md
##
## The page reads its data from JavaScript files rather than JSON, as
## browsers refuse fetch() of file:// URLs but do run <script src>.
##   web/imageData.js - every image and tag; rebuilt only by BUILDWEB
##   web/silStamp.js  - when sil last used the library, and when the data
##                      was last built; rewritten by every run, so the page
##                      can tell when its data is out of date

srcLib "index"
srcLib "tags"

## Page files copied from templates/web on each BUILDWEB, so a library
## picks up page changes from SIL updates: template name -> library path
declare -gA _silWebFiles=(
    [WebSIL.html]=WebSIL.html
    [websil.js]=web/websil.js
    [websil.css]=web/websil.css
)

#######################################
# Escape text for use inside a JSON string. Control characters, which
# can only arrive in a command line, become spaces.
# Arguments:
#   $1 - Text
# Outputs:
#   Escaped text, without quotes, to STDOUT
#######################################
function jsonEscape {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//[[:cntrl:]]/ }"
    printf '%s' "$s"
}

#######################################
# Write web/silStamp.js, recording that sil is using the library now, and
# when the page data was built. Only for libraries with a web page.
# Globals:
#   SIL_LIBRARY, _silCommandLine
# Arguments:
#   $1 - Optional epoch seconds the page data was built; otherwise kept
#        from the existing stamp
# Returns:
#   0 on success or with no web page; 1 if the stamp can't be written
#######################################
function webStamp {
    local web="$SIL_LIBRARY/web" built="${1:-}" now tmp
    [[ -d "$web" ]] || return 0
    if [[ -z "$built" ]]; then
        built="$(grep -o '"built":[0-9]*' -- "$web/silStamp.js" 2> /dev/null)"
        built="${built#*:}"
    fi
    ## When building, the build is the latest change: a clock read here
    ## could tick past it, and make fresh data look out of date
    now="${1:-$(date +%s)}"
    tmp="$(silMktemp)" || return 1
    printf 'window.SIL_STAMP = {"changed":%s,"changedText":"%s","command":"%s","built":%s};\n' \
        "$now" "$(date -d "@$now" '+%Y-%m-%d %H:%M:%S')" \
        "$(jsonEscape "${_silCommandLine:-sil}")" "${built:-0}" > "$tmp" \
        && placeLibraryFile "$tmp" "$web/silStamp.js"
}

#######################################
# Test whether this run only reads the library (CHECK alone), so it
# doesn't make the page data out of date.
# Globals:
#   _silArgs, SIL_LINK, SIL_REMAP
# Returns:
#   0 if the run only reads, 1 otherwise
#######################################
function runOnlyReads {
    flagIsSet CHECK && ! flagIsSet REBUILD && ! flagIsSet BUILDWEB \
        && (( ${#_silArgs[@]} == 0 )) && [[ -z "${SIL_LINK:-}${SIL_REMAP:-}" ]]
}

#######################################
# List the facts the page needs, as tab separated records in the order
# webDataJs reads them:
#   D <tag path>                  - every tag folder, except the date tag
#   A <alias path> <target path>  - LINK aliases
#   L <folder> <image file name>  - every tag link, date tag included
#   I <image file name> <bytes>   - every stored image
# Tag folders reached only through an alias are not listed twice.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Outputs:
#   Records to STDOUT
#######################################
function webFacts {
    local tags="$SIL_LIBRARY/tags" alias target
    (
        cd -- "$tags" || exit 1
        find . -mindepth 1 -type d ! -path "./$_silDateTag" ! -path "./$_silDateTag/*" \
            -printf 'D\t%P\n' | LC_ALL=C sort
        find . -type l -xtype d ! -path "./$_silDateTag/*" -printf '%P\n' | LC_ALL=C sort \
            | while IFS= read -r alias; do
                target="$(realpath --relative-to=. -- "$alias" 2> /dev/null)" || continue
                printf 'A\t%s\t%s\n' "$alias" "$target"
            done
        find . -type l -xtype f -printf 'L\t%h\t%f\n' | LC_ALL=C sort
    )
    find "$SIL_LIBRARY/images" -mindepth 3 -maxdepth 3 -type f -printf 'I\t%f\t%s\n' \
        | LC_ALL=C sort
}

#######################################
# Turn webFacts records into the page's data file. Each image becomes
# [hash, suffix, bytes, date added or null, [tag numbers]], the numbers
# indexing the tags list, to keep the file small for large libraries.
# Globals:
#   SIL_LIBRARY, _silDateTag
# Arguments:
#   $1 - Epoch seconds to record as the build time
# Inputs:
#   webFacts records on STDIN
# Outputs:
#   JavaScript to STDOUT
#######################################
function webDataJs {
    ## The path goes through the environment, as awk -v would read
    ## backslashes in it as escapes. jsonEscape has already escaped it
    WEBSIL_LIBRARY="$(jsonEscape "$SIL_LIBRARY")" awk -F'\t' -v built="$1" \
        -v builtText="$(date -d "@$1" '+%Y-%m-%d %H:%M:%S')" -v dateTag="$_silDateTag" '
        ## Tag names, suffixes and dates hold no characters needing escapes
        function q(s) { return "\"" s "\"" }
        $1 == "D" { tagNum[$2] = nTags; tagList = tagList (nTags++ ? "," : "") q($2); next }
        $1 == "A" { aliasList = aliasList (nAlias++ ? "," : "") "[" q($2) "," q($3) "]"; next }
        $1 == "L" {
            dir = substr($2, 3)
            if (index(dir, dateTag "/") == 1) {
                if (match(dir, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/))
                    added[$3] = substr(dir, RSTART)
            } else if (dir in tagNum) {
                ## Test first: reading imgTags[$3] would create it
                sep = ($3 in imgTags) ? "," : ""
                imgTags[$3] = imgTags[$3] sep tagNum[dir]
            }
            next
        }
        ## Rows are written as they come, as building one string of them
        ## would slow to a crawl for a large library
        function start() {
            if (started++) return
            printf "window.SIL_DATA = {\"version\":1,\"built\":%s,\"builtText\":%s,", built, q(builtText)
            printf "\"library\":%s,\n\"tags\":[%s],\n\"aliases\":[%s],\n", "\"" ENVIRON["WEBSIL_LIBRARY"] "\"", tagList, aliasList
            printf "\"images\":["
        }
        $1 == "I" {
            if ($2 !~ /^[0-9a-f]+\.[a-z0-9]+$/ || length($2) < 42) next
            start()
            dot = index($2, ".")
            printf "%s[%s,%s,%s,%s,[%s]]", (nImages++ ? ",\n" : "\n"), q(substr($2, 1, dot - 1)), \
                q(substr($2, dot + 1)), $3, (($2 in added) ? q(added[$2]) : "null"), imgTags[$2]
        }
        END { start(); printf "]};\n" }'
}

#######################################
# Build the library's web page (BUILDWEB): copy WebSIL.html and its
# support files into place, and write web/imageData.js from the library.
# The page and its data are kept out of git, as each copy of a library
# builds its own.
# Globals:
#   SIL_LIBRARY, myDir, _silWebFiles
# Outputs:
#   Progress, and the page's location, to STDERR
# Returns:
#   0 on success, 1 if any file can't be written
#######################################
function buildWeb {
    local lib="$SIL_LIBRARY" name tmp built count
    srcLib "replace"
    msgInfo "BUILDWEB: building the library web page"
    mkdir -p -- "$lib/web" || return 1
    for name in "${!_silWebFiles[@]}"; do
        tmp="$(silMktemp)" || return 1
        cp -- "$myDir/templates/web/$name" "$tmp" \
            && placeLibraryFile "$tmp" "$lib/${_silWebFiles[$name]}" || return 1
    done
    ensureFileLine "$lib/.gitignore" "/web/" || return 1
    ensureFileLine "$lib/.gitignore" "/WebSIL.html" || return 1

    built="$(date +%s)"
    tmp="$(silMktemp)" || return 1
    if ! webFacts | webDataJs "$built" > "$tmp"; then
        rm -f -- "$tmp"
        msgWarn "[!] Could not write the web page data"
        return 1
    fi
    count="$(grep -c '^\["' -- "$tmp")"
    placeLibraryFile "$tmp" "$lib/web/imageData.js" || return 1
    webStamp "$built" || return 1
    msgInfo "  $count images. Open in a web browser: $lib/WebSIL.html"
}
