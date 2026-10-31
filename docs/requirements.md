Project requirements for Simple Image Library (SIL), formated for both human and
agent consumption

# TECH-01 Keep it simple

* Utilize core bash functionality wherever possible
* For more advanced behavior, rely on applications and utilities available from
  standard Debian / Ubuntu repositories.
* Modularize functionality to allow independent usage and ease testing
* This codebase / repository _is_ the application. There is no compilation
* Each library is simply a folder structure with images, symlinks to images, and
  some basic utility functions.

# UI-01 User transparency & messaging

* Provide verbose feedback to user
* If an operation fails, determine (as best as possible) why it failed
* If the user needs to take action outside of SIL (eg install a tool) print out
  the command to do so (but do not run), explain why the action is needed, and
  how SIL will be limited if the action is not taken

# UI-02 User messaging

* Core internal functions will be used to standardize how messaging is presented
* ANSI color coding will be used to visually highlight different kinds of messages
* Message functions share the `msg` prefix, avoiding collisions with system
  commands (eg `/usr/bin/info`) and shell conventions
* `msgError` - Red with yellow background. Halts execution
* `msgWarn` - Red, indicates a problem but exection can continue
* `msgInfo` - Blue, information for user
* `msgDebug` - Developer debugging output

# UI-03 Parameters and command line usage

See [parameters.md](./parameters.md) for details on parameter specification

See also `REQ-02` for accepted mechanisms to specify parameters

# REQ-01 Command line operation

* The tool will function from a linux command line
* Interaction will be via `sil.sh`, which will be symlinked to `sil`
* Functionality will be broken into bash scripts within `src/`
* `sil.sh` will source in functions as needed, via `srcLib`. Functions can
  source additional functions as needed

# REQ-02 Configuration and customization

See also `UI-03` for more details on parameters

`sil.sh` will consume parameters from four sources:

  1. `~/.sil.conf` - the user's global preference file. Hidden, in `$HOME`
  2. From `sil.conf` within a specific image library folder (not hidden). These
     parameters take precedence over the global preference file for that
     library. New libraries get a copy of `templates/sil.conf`
  3. From the command line, which takes precedence over the preference files
  4. From parsing a manifest file, which will takes precedence to any other
     parameter sources

# REQ-03 Image URIs

SIL will locate images through the following URIs:

* URLs, either standard web or onion links
* Local file paths, either relative or absolute
  * On the command line, relative paths are relative to the current folder
  * In a manifest, relative paths are relative to the manifest's folder
    (`REQ-06`)
* Internal image hash
* Any mixture of the above, recorded one per line in a manifest file

# REQ-04 Image recovery

* URLs will be recovered via curl
  * Only `http` and `https` URLs are supported (`UNSUPPORTED` otherwise)
  * Requests identify SIL with a User-Agent, as eg Wikimedia asks of
    automated tools, and time out (30 seconds to connect, 5 minutes in all)
  * Images are initially recovered to a temp directory pending later processing
  * Onion URLs are always recovered with torsocks
  * All URLs can optionally be recovered with torsocks if the `TOR` parameter is set
* Local files (via filepath) are copied to a temp directory pending later processing
* Files in the temp directory are saved without a suffix, so their format is
  judged by content alone (`REQ-05`)
* All temporary files SIL makes, for any operation, are kept in the library's
  own `.tmp` folder, never the system temp folder. This keeps them on the same
  disk as the library, so moving finished files into place is instant, and
  leftovers are easy to find. `.tmp` is excluded from git (`REQ-10`)
* Image hashes simply identify an already-ingested file for further operations

# REQ-05 Image hashing, fingerprints and storage

Each stored image has two identifiers with different jobs:

* Its **hash** - the SHA1 of the stored file (`sha1sum`). Names the file and
  identifies the image exactly
* Its **fingerprint** - from `findimagedupes`. Used only to find similar images

## Hashing and storage

* The hash is computed after all other image manipulation (eg `REQ-07`
  shrinking), from the file exactly as stored
* The stored file name is the hash plus a suffix for its format, eg `.jpg`
* Images are stored within an `images` folder at the base level of the library
* There will be two additional subdirectory levels in the `images` folder
  * The first level will be the leftmost first two characters of the hash
  * The next sublevel will be the next leftmost two characters
  * So an image `f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg` will be stored at:
    * `images/f1/d2/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * These additional subdirectories are to prevent too many files from being in
    one folder
* Any stored file can be checked against its name with `sha1sum` (`REQ-09`)

## Format

* Image format is determined from content with ImageMagick
  (`identify -format %m`), never from the file or URL suffix
  * Supported: JPEG, PNG, GIF, WEBP, BMP, TIFF. SVG is shelved for now
  * Files are inspected without a suffix, as ImageMagick otherwise takes hints
    from it (eg attempting to render `.html` files)

## Fingerprints and similarity

* The goal is similarity, not identity: images that would look the same to a
  person (eg a meme rescaled or converted to another format) count as the
  same. Heavily compressed copies may legitimately fail to match
* A fingerprint is 256 bits: a heavily blurred, contrast-stretched 16x16
  black-and-white thumbnail of the image. Similar images have fingerprints
  differing in a few bits; their hashes are unrelated
* Similarity is the share of bits two fingerprints have in common. Following
  findimagedupes, at a similarity of `T`% at most `int(2.56 x (100 - T))` bits
  may differ: 90% allows 25 bits, 95% allows 12
* The fingerprint is computed from the first frame of a temporary copy
  stripped of profiles and metadata (`convert -strip`), as findimagedupes
  rejects some harmless flaws, eg "iCCP: known incorrect sRGB profile"
* An empty or malformed fingerprint means the image could not be read
  (`BADIMAGE`, `REQ-08`)

## Fingerprint index

* Fingerprints of all stored images are kept in `images/fingerprints.txt`, a
  plain text file. Lines starting with `#` are comments; every other line is:
  * `<hash> <fingerprint as 64 hexadecimal characters>`
  * Lines are kept sorted by hash (C locale), so changes and merges stay small
    under git (`REQ-10`)
* It contains hashes, not paths, so a library can be moved or renamed freely
* A new image is compared against every fingerprint in the index at the
  `THRESHOLD` similarity
  * No match: the image is new, and is stored and added to the index
  * One or more matches: the image is a `DUPE` (`REQ-08`) of the closest match
    (fewest differing bits). The existing image is kept, the new one discarded,
    and remaining operations (eg tagging) apply to the existing image
* The index can be regenerated from the stored images at any time (`REQ-09`)

## Sources

* Where each image came from is kept in `images/sources.txt`, a plain text
  file. Lines starting with `#` are comments; every other line is:
  * `<hash> <source>`
* A line is added when an image is stored, and when a `DUPE` arrives from a
  new source; the `DUPE`'s source is recorded against the existing image
* The same source for the same image is never recorded twice. The same source
  for a different image is (eg a URL whose content has changed)
* URLs are recorded exactly as given. Local files are recorded as
  `file:<name>`, without their folders, as the library may be shared
* Hash URIs are not sources, and are not recorded
* Unlike the fingerprint index, sources can't be regenerated, so the file is
  only ever added to. `REBUILD` changes hashes in it when it renames an image
  (`REQ-09`), and never removes a line
* Lines are kept sorted (C locale) for git (`REQ-10`)

# REQ-06 Manifest files

* Leading and trailing whitespace is ignored on each line of the manifest file
* Lines beginning with `#` are comment lines and are ignored
* Blank lines are ignored
* A manifest file contains one or more image URIs for recovery or other image operations
* Each URI occupies one line of the file with no other information
* The file also may contain zero or more parameter settings
* Parameters are specified by `PARAM=VALUE`
  * `PARAM` will be parsed case-insensitive
  * Parameters apply to all URIs following them
  * Parameters can be changed an arbitrary number of times in the manifest.
    Changes apply to all subsequent URIs, unless changed again
* Manifest files are provided in the same context as URIs, but are recognized as
  such by being text files with a `.txt` suffix.
* Relative local paths in a manifest are relative to the manifest's own folder,
  not the current folder, so a manifest works wherever SIL is run from
* Parameter changes last only until the end of the manifest; settings are then
  restored, so each manifest gives the same result however it is run
* `LIBRARY`, `CHECK` and `REBUILD` can't be set in a manifest, and are ignored
  with a warning
* A line shaped like `NAME=VALUE` with an unrecognized `NAME` is reported and
  ignored, rather than treated as a file
* A failed URI is reported and processing continues with the next line

# REQ-07 Image shrinking

Optional reduction of image file size, controlled by the `SHRINK`,
`SHRINKTRIGGER`, `SHRINKMINSAVE` and `FLATTEN` parameters (see
[parameters.md](./parameters.md))

* Shrinking happens after recovery and before fingerprinting (`REQ-05`)
* An image is only shrunk if it is at least `SHRINK` x `SHRINKTRIGGER` bytes
* Shrinking re-encodes as JPEG using ImageMagick's `jpeg:extent`, which picks
  the JPEG quality that fits the target size
* The original is kept, and the user told why, if:
  * The image is animated
  * The image has transparency (which JPEG cannot store), unless `FLATTEN` is
    set, in which case it is first placed on a white background
  * ImageMagick fails
  * The saving is less than `SHRINKMINSAVE`
  * The shrunk image no longer matches the original (or, with `FLATTEN`, the
    flattened image) at a fixed 95% similarity (at most 12 of 256 fingerprint
    bits differ), regardless of `THRESHOLD`. This catches conversions that
    ImageMagick has damaged
* A kept shrunk image replaces the original for the rest of processing, and its
  stored suffix becomes `.jpg`

# REQ-08 Handling issues and problems during image processing

There are a variety of events or issues that can occur when a request is made
against an image URI. Each is reported to the user (`msgWarn` for failures,
`msgInfo` otherwise), naming the URI, and processing moves on to the next URI.

## Outcomes

Successful outcomes, with their status tag:

| Status  | Meaning                                                     |
| ------- | ----------------------------------------------------------- |
| ADDED   | Recovered and added to the library                          |
| SHRINK  | Recovered, shrunk (`REQ-07`) and added                      |
| DUPE    | Recovered, but already in the library. Reported with the existing image's hash and how many fingerprint bits differ; remaining operations (eg tagging) apply to the existing image |
| FOUND   | A hash URI (`REQ-03`) matched a stored image; remaining operations apply to it |

Failures, with their reason tag. No further action is taken on the image. This
list is expected to grow as new failure modes are found; tags are at most 12
characters.

| Reason      | Meaning                                                     |
| ----------- | ----------------------------------------------------------- |
| UNREACHABLE | Could not connect to the website (eg DNS failure, refused)  |
| TIMEOUT     | Website did not respond in time                             |
| NOTFOUND    | Website available, but the URL was not found (HTTP 404/410) |
| RATELIMIT   | Website refused because of too many requests (HTTP 429). Common over Tor, where many users share few exit nodes |
| HTTPERROR   | Any other HTTP error, eg 403 forbidden or 500 server error  |
| NOTIMAGE    | Something was returned, but not an image, eg an HTML login or "not allowed" page |
| BADIMAGE    | An image, but damaged (eg truncated) or could not be fingerprinted |
| UNSUPPORTED | An image, but in an unsupported format (eg SVG)             |
| TORFAIL     | The request failed within Tor (eg Tor service not running)  |
| NOFILE      | Local file does not exist                                   |
| UNREADABLE  | Local file exists but cannot be read (permissions)          |
| NOHASH      | A hash URI (`REQ-03`) does not match any image in the library |
| STOREFAIL   | The image could not be written into the library (eg disk full) |

## Reporting

* All messages go to STDERR, for both command line and manifest usage
* `sil` exits with status 1 if any URI or manifest failed, 0 otherwise
* For manifest file parsing, reports are also written to two log files beside
  the manifest. If the original manifest was `foo.txt`, then:
  * Both files are overwritten on each run
  * An error log named `foo.txt.err`
    * Formatted as a manifest, so failures can be reviewed, edited, and re-run
      by renaming it to a `.txt` file. The `.err` suffix deliberately stops it
      being used as a manifest by accident
    * Written as failures happen, so it is useful even if a run is
      interrupted. A header explains how to retry
    * All parameters in effect (except `LIBRARY`, `CHECK` and `REBUILD`) are
      written before the first failed URI, and each one again whenever it
      changes before a later failed URI. A retry therefore uses the original
      settings, whatever the configuration files or command line say then
    * Values are written so they read back the same, eg sizes in bytes
      (`SHRINK=512000b`) and percents with `%`
    * Relative paths are kept as written; they still work for a renamed copy
      in the same folder
    * With no failures, it holds only its header and `# No failures`
    * Failed URIs are written one per line, each preceded by a comment of 80
      characters or less giving the reason tag and explaining why it failed
  * An informative log named `foo.txt.md`
    * A compact markdown file
    * An h1 header `# Load report for foo.txt`, then the run's date and library
    * A bulleted list legend for each status that occurs in the run
    * A markdown table with three columns
      * Status - per the outcome table above
      * Hash - The leftmost 12 characters of the stored image's hash (`REQ-05`);
        for a `DUPE`, the hash of the existing image it matched
      * URI - The URL, path or full hash of the image, as requested by the user
    * If any URIs failed, an h1 header `# Failed image download`, followed by:
      * A bulleted list legend of the reason tags that occur in the run, and
        only those
      * A markdown table with two columns: Reason and URI
  * `|` in a URI is escaped, so the tables stay intact
  * If the manifest's folder can't be written, SIL warns and runs without logs

# REQ-09 Library maintenance

Tools to check a library's consistency and rebuild what can be derived from the
stored images. Run as action parameters, eg `sil CHECK` (see
[parameters.md](./parameters.md)), from within a library or with `LIBRARY`

* `CHECK` reports problems without changing anything, and exits with status 1 if
  any are found:
  * A stored file whose `sha1sum` does not match its name (damaged, or edited
    after storage)
  * A stored file in the wrong `images/xx/yy/` folder for its name
  * An unexpected file in `images` (not named `<hash>.<suffix>`)
  * A stored image missing from the fingerprint index, or an index entry with
    no stored image
  * A malformed or repeated index line
  * A malformed sources line, or a source for an image that isn't stored
  * A tag symlink whose target no longer exists
  * Date tag next/previous links that are missing or out of date (`TAG-02`)
  * A missing standard library file (`REQ-10`)
* `REBUILD` repairs what can be derived from the stored images, keeping tags
  wherever possible:
  * Adds any missing standard library files (`REQ-10`)
  * Renames each stored image to its current `sha1sum` and format suffix, in
    its correct `images/xx/yy/` folder. This covers images edited after
    storage, misplaced files and wrong suffixes
  * Tag links to a renamed image are replaced by links named after, and
    pointing to, its new file name. Its sources move to its new hash
  * If an image's correct name is already taken by an identical image, the
    extra copy is removed and its tags moved to the remaining one
  * Files not named like stored images, or not readable as images, are left
    alone and reported
  * Remakes the date tag's next/previous links between days (`TAG-02`)
  * Finally regenerates the fingerprint index, replacing the existing index
    only once the new one is complete
* Each problem found by `CHECK` is reported with the action that would fix it,
  eg running `REBUILD`

# REQ-10 Git-friendly libraries

A library can be shared as a git repository: others `git clone` it, keep up to
date with `git pull`, and can add images themselves and `git push`

* A library is git-ready from creation. New libraries (and `REBUILD`, for
  older ones) get these files from `templates/`:
  * `.gitignore` - excludes the `.tmp` folder and manifest log files
    (`*.txt.err`, `*.txt.md`, `REQ-08`)
  * `.gitattributes` - merges `images/fingerprints.txt` and
    `images/sources.txt` with git's built-in `union` driver, so images added
    by two people are combined rather than reported as a conflict
* Git does not keep empty folders, so `tags/.gitkeep` and the fingerprint
  index header keep `tags` and `images` in a fresh clone, which is then still
  recognized as a library
* Everything in a library is plain files and relative symlinks, so the same
  repository works wherever it is cloned
* SIL does not run git itself; sharing is up to the user. After a `git pull`,
  `sil CHECK` confirms the library is consistent, and `sil REBUILD` repairs a
  merged fingerprint index (eg a line repeated by a union merge)
* Known limits:
  * Tag links are symlinks, which git on Windows does not create by default
  * Git keeps every version of every image, so a repository only grows; images
    removed later still take space in its history

# TAG-01 Tagging

Tags are the core of SIL. Core image storage is not conducive for browsing, as
images are named after their hash and stored in a directory
structure meant to manage file system usage but not be friendly to humans.

Tagging requirements are broken out in the `TAG` section of
[parameters.md](parameters.md)

# TAG-02 Date tags

Every image is tagged with the day it was first added to the library, making
the library browsable by date

* `Date` is a reserved top-level tag, at `tags/Date`. Users can't apply it
  (`TAG=Date/...` is ignored with a warning, in any case)
* When an image is first stored (`ADDED` or `SHRINK`, `REQ-08`), it is linked
  into `tags/Date/YYYY/YYYY-MM-DD/` for the current local date, with folders
  created as needed. A `DUPE` gets no new date tag
* Each day folder links to its neighbouring days, for browsing:
  * `previous-YYYY-MM-DD` - links to the most recent earlier day folder
  * `next-YYYY-MM-DD` - links to the next later day folder
  * Neighbours are found across years, eg `2026-01-02` links back to
    `2025-12-30`
  * The links are named after their target day, so if two clones of a library
    each add a day, a git merge keeps both links rather than conflicting.
    `CHECK` reports the extra link and `REBUILD` remakes the chain
* A new day is normally the latest, but one earlier than an existing day (eg
  from a clock change, or a merge) is inserted between its neighbours
