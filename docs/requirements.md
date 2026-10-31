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
  * Images are initially recovered to a temp directory pending later processing
  * Onion URLs are always recovered with torsocks
  * All URLs can optionally be recovered with torsocks if the `TOR` parameter is set
* Local files (via filepath) are copied to a temp directory pending later processing
* Files in the temp directory are saved without a suffix, so their format is
  judged by content alone (`REQ-05`)
* Image hashes simply identify an already-ingested file for further operations

# REQ-05 Image hashing and storage

Image hasing is used to deduplicate images in the library

* Deduplication is performed using `findimagedupes` to generate a fingerprint
  * The `THRESHOLD` parameter sets the `--threshold` parameter
  * The goal is similarity, not identity: images that would look the same to a
    person (eg a meme rescaled or converted to another format) count as the
    same. Heavily compressed copies may legitimately fail to match
  * The fingerprint is computed from the first frame of a temporary copy
    stripped of profiles and metadata (`convert -strip`), as findimagedupes
    rejects some harmless flaws, eg "iCCP: known incorrect sRGB profile"
  * An empty or malformed fingerprint means the image could not be read
    (`BADIMAGE`, `REQ-08`); it must never be hashed
* Image format is determined from content with ImageMagick
  (`identify -format %m`), never from the file or URL suffix
  * Supported: JPEG, PNG, GIF, WEBP, BMP, TIFF. SVG is shelved for now
  * Files are inspected without a suffix, as ImageMagick otherwise takes hints
    from it (eg attempting to render `.html` files)
* The fingerprint produced by findimagedupes appears fairly non-random. For this
  reason, the fingerprint is passed throught `sha1sum` to generate a hash. This
  hash will represent the basename of the image as stored in the library
  * The hash is of the 44 character base64 fingerprint string alone, with no
    trailing newline: `printf '%s' "$fingerprint" | sha1sum`
  * Each sha1 hash will also have the appropriate file type suffix, eg `.jpg`,
    added to it
  * Terminology: the SHA1 hash is an alternate accession for the fingerprint,
    unique short of astronomically unlikely collisions, and easier on the eye.
    "Fingerprint" in user-facing text and these docs may refer to either; where
    the difference matters (similarity comparison needs the raw fingerprint),
    say "raw fingerprint" or "SHA1 hash"
* Fingerprints are only calculated after all other image manipulation has occured
* Images will be stored within an `images` folder at the base level of the library
* There will be two additional subdirectory levels in the `images` folder
  * The first level will be the leftmost first two characters of the sha1 hash
  * The next sublevel will be the next leftmost two characters
  * So an image `f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg` will be stored at:
    * `images/f1/d2/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * These additional subdirectories are to prevent too many files from being in
    one folder

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
| DUPE    | Recovered, but already in the library. Reported with its fingerprint; remaining operations (eg tagging) apply to the existing image |

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
    * Parameters in effect are written before the first failed URI, and written
      again whenever a parameter changes before a later failed URI
    * Failed URIs are written one per line, each preceded by a comment of 80
      characters or less giving the reason tag and explaining why it failed
  * An informative log named `foo.txt.md`
    * A compact markdown file
    * An h1 header `# Load report for foo.txt`
    * A bulleted list legend for each status that occurs in the run
    * A markdown table with three columns
      * Status - per the outcome table above
      * Fingerprint - The leftmost 12 characters of the image's SHA1 hash
      * URI - The URL, path or full hash of the image, as requested by the user
    * If any URIs failed, an h1 header `# Failed image download`, followed by:
      * A bulleted list legend of the reason tags that occur in the run, and
        only those
      * A markdown table with two columns: Reason and URI

# TAG-01 Tagging

Tags are the core of SIL. Core image storage is not conducive for browsing, as
images are named after their fingerprint hash and stored in a directory
structure meant to manage file system usage but not be friendly to humans.

Tagging requirements are broken out in the `TAG` section of
[parameters.md](parameters.md)