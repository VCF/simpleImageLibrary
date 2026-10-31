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
* Internal image hash
* Any mixture of the above, recorded one per line in a manifest file

# REQ-04 Image recovery

* URLs will be recovered via curl
  * Images are initially recovered to a temp directory pending later processing
  * Onion URLs are always recovered with torsocks
  * All URLs can optionally be recovered with torsocks if the `TOR` parameter is set
* Local files (via filepath) are copied to a temp directory pending later processing
* Image hashes simply identify an already-ingested file for further operations

# REQ-05 Image hashing and storage

Image hasing is used to deduplicate images in the library

* Deduplication is performed using `findimagedupes` to generate a fingerprint
  * The `THRESHOLD` parameter sets the `--threshold` parameter
* The fingerprint produced by findimagedupes appears fairly non-random. For this
  reason, the fingerprint is passed throught `sha1sum` to generate a hash. This
  hash will represent the basename of the image as stored in the library
  * Each sha1 hash will also have the appropriate file type suffix, eg `.jpg`,
    added to it
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

# REQ-07 Image shrinking

Optional reduction of image file size, controlled by the `SHRINK`,
`SHRINKTRIGGER` and `SHRINKMINSAVE` parameters (see
[parameters.md](./parameters.md))

* Shrinking happens after recovery and before fingerprinting (`REQ-05`)
* An image is only shrunk if it is at least `SHRINK` x `SHRINKTRIGGER` bytes
* Shrinking re-encodes as JPEG using ImageMagick's `jpeg:extent`, which picks
  the JPEG quality that fits the target size
* The original is kept, and the user told why, if:
  * The image is animated, or has transparency (which JPEG cannot store)
  * ImageMagick fails
  * The saving is less than `SHRINKMINSAVE`
  * The shrunk image no longer matches the original at a fixed 90% similarity
    (`findimagedupes`), regardless of `THRESHOLD`. This catches conversions
    that ImageMagick has damaged
* A kept shrunk image replaces the original for the rest of processing, and its
  stored suffix becomes `.jpg`

# TAG-01 Tagging

Tags are the core of SIL. Core image storage is not conducive for browsing, as
images are named after their fingerprint hash and stored in a directory
structure meant to manage file system usage but not be friendly to humans.

* At the root level of the library is a folder 