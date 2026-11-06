## Command line help

#######################################
# Print command line usage. Unlike msg* output this goes to STDOUT without
# color, as it is the requested result and may be piped, eg to less. Lines
# are kept within 80 columns; test/help.bats checks this, and that every
# parameter is listed.
# Outputs:
#   Help text to STDOUT
#######################################
function showHelp {
    cat << 'EOF'
Simple Image Library (SIL) - collect and organize images from the command line

Usage:
  sil [PARAMETER...] [URI | MANIFEST.txt]...
  sil -h | --help

Arguments:
  URI            An image: a web or onion URL, a local file path, or the hash
                 of an image already in the library
  MANIFEST.txt   A text file of URIs and parameters, one per line

Options:
  -h, --help     Show this help and exit

Parameters are written NAME=VALUE, or just NAME for flags, in any case, and
must come before any URIs. Flags are turned off with NAME=off.

Library:
  LIBRARY=PATH         Library folder, created if needed. If not given: the
                       library containing the manifest (for its URIs), the
                       library containing the current folder, then LIBRARY in
                       ~/.sil.conf

Tags and images:
  TAG=TAGS             Apply tags, comma separated; / or : makes a hierarchy
                       (alias TAGS)
  UNTAG=TAGS           Remove tags from stored images; '*' removes all
                       (alias UNTAGS)
  REMOVE               Remove images from the library
  LINK='SRC -> DEST'   Make tag SRC an alias of tag DEST
  REMAP='SRC -> DEST'  Quietly replace tag SRC with tag DEST, now and later

Shrinking:
  SHRINK=SIZE          Target size for still images, eg 500kb (default 0, off)
  SHRINKTRIGGER=N      Only shrink images at least N x SHRINK (default 2)
  SHRINKMINSAVE=PCT    Keep the original unless this is saved (default 25%)
  SHRINKVID=LEVEL      Convert animations and videos to AVIF, at quality HIGH,
                       MEDIUM, LOW or OFF (default OFF)
  FLATTEN              Allow SHRINK of transparent images, placed on white

Downloads and duplicates:
  THRESHOLD=PCT        Similarity at which images are duplicates (default 90%)
  REFETCH              Download URLs even if already recorded as a source
  KEEPLARGER           Replace a stored image if a duplicate has more pixels
  TOR                  Download through torsocks (alias USETOR)

Maintenance:
  CHECK                Report problems in the library, changing nothing
  REBUILD              Repair the library from its stored images

Manifests only:
  STOPSIL              Stop reading the manifest at this line

Settings are read in this order, with later sources taking precedence:
  ~/.sil.conf          Your defaults
  <LIBRARY>/sil.conf   Settings for one library
  Command line         This run
  Manifest             The URIs that follow, until the manifest ends

Examples:
  # Create a library
  sil LIBRARY=~/Pictures/sil

  # From within a library, add a tagged image
  sil TAG=Animal/Dog https://example.com/dog.jpg

  # Process a manifest
  sil LIBRARY=~/Pictures/sil manifest.txt

  # Remove a tag from a stored image
  sil UNTAG=Animal/Dog ./dog.jpg

  # Repair, then check, a library
  sil REBUILD CHECK

Exit status:
  0 if everything succeeded, 1 if anything failed

Documentation: https://github.com/VCF/simpleImageLibrary
EOF
}
