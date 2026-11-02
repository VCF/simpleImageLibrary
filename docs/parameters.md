# Recognized parameters

This file describes the parameters recognized by SIL. Every parameter that can
be set in a library's `sil.conf` also has a commented example in
[templates/sil.conf](../templates/sil.conf); see "Adding a parameter" in
[conventions.md](./conventions.md).

* Parameters are parsed case-insensitive
  * Parameters are held internally as uppercase environment variables, prefixed
    with `SIL_`. So the parameter `TAG` will be stored in `$SIL_TAG`
  * In documentation, parameters will be shown uppercase
* Some parameters have aliases - these will be internally remapped to their
  "main" parameter name when parsed. For example, if a user passes parameter `TAGS`, it is recognized as an alias
* On the command line, parameters are included after `sil` and before the URI or
  manifest path
* Most parameters will be of `PARAM=VALUE` format
  * `sil TAG=Meme https://example.com/funny.jpg`
* Some parameters may be set as flags by just passing them
  * `sil TOR https://example.com/funny.jpg`
  * Flags can optionally have a value, eg `TOR=1`. The value will be ignored
  * Flags can be unset by passing `0`, `no`, `false` or `off` (any case), eg
    `TOR=0` or `TOR=off`
* Multiple parameters can be separated by spaces
  * `sil TAG=Meme TOR https://example.com/funny.jpg`
* Parameter values can be quoted if they have special characters. The quotes can
  optionally include the parameter name as well.
  * `sil TAG='Meme/Politics' https://example.com/funny.jpg`
  * `sil 'TAG=Meme/Politics' https://example.com/funny.jpg`
* Setting a parameter again replaces its previous value; values are never
  merged. Parameters that accept several values (eg `TAG`) take them as one
  comma-separated value
  * `sil TAG=Meme TAG=Politics ...` results in just `Politics`
  * `sil TAG=Meme,Politics ...` results in both
* In configuration and manifest files, values may also be quoted; one pair of
  matching surrounding quotes is removed
* Some parameters have a type, and invalid values halt SIL with an example of
  the expected format:
  * Size: a file size such as `500kb` or `2mb` (see `SHRINK`)
  * Percent: a whole number 0-100, with optional `%`, eg `25` or `25%`
  * Number: a positive number, decimals allowed, eg `2` or `1.5`
  * Level: `HIGH`, `MEDIUM`, `LOW` or `OFF`, any case (see `SHRINKVID`)

## Configuration files

Parameters can be stored in two `PARAM=VALUE` files (see `REQ-02` for
precedence). Blank lines and lines starting with `#` are ignored.

Configuration files hold settings that apply broadly. Some parameters can't be
set in them; SIL warns and ignores those lines:

* `TAG`, `UNTAG`, `REMOVE` and `LINK` - in neither file. They apply to
  individual images or are one-time actions; use the command line or a manifest
* `LIBRARY` - in `~/.sil.conf` only, as a default library

| File                  | Hidden | Scope                                     |
| --------------------- | ------ | ----------------------------------------- |
| `~/.sil.conf`         | Yes    | User's global defaults, in `$HOME`        |
| `<LIBRARY>/sil.conf`  | No     | One library; created from `templates/sil.conf` |

## LIBRARY

The library parameter specifies the file path to the image library

* Can be set in `~/.sil.conf` as a default library, or in a manifest, but not
  in a library's own `sil.conf`, which is only read once the library is
  already known

* A library is a folder containing `images` and `tags` folders
* The library is chosen in this order:
  1. `LIBRARY` set at the top of a manifest, for that manifest's URIs (see
     `REQ-06`)
  2. `LIBRARY` given on the command line
  3. The library containing the current folder. The current folder and each
     of its parents are checked, so running SIL from eg `tags/Animal/Dog`
     finds the library
  4. `LIBRARY` set in `~/.sil.conf`
* A leading `~` is expanded to the home folder, including in `~/.sil.conf`
* If the chosen folder does not exist, or is empty, it is made into a new
  library: `images` and `tags` folders are created, and `sil.conf` is copied
  from `templates/sil.conf`
  * `sil LIBRARY=~/Pictures/sil` with no images creates a library and stops
* If the folder exists, is not empty, and is not a library, SIL halts rather
  than add its folders to it, and explains how to proceed
* If no library can be determined, SIL halts with instructions for specifying
  or creating one

## TAG

* ALIAS: `TAGS`

The tag parameter defines one or more tags within the library

* Can't be set in configuration files: tags are applied to individual images,
  not set for a whole library
* All tag folders are subdirectories of `tags`
* Tags are case-insensitive, but will be written in the file system in the
  first-observed case
  * `TAG=Bird` will search to see if any tags folder exists that matches,
    regardless of case. `Bird`, `bird`, `BiRD` etc - all are considered matches
  * If found, that folder will be used for further operations
  * If not, a new folder will be created using the case provided
* Tags can be organized in subfolder hierarchies
  * These hierarchies are separated by either `/` or `:`
  * `Animal:Mammal:Dog` would then be found in `tags/Animal/Mammal/Dog`
* Multiple tags can be passed separated by commas. Repeating `TAG=` replaces
  the earlier value rather than adding to it
  * `TAG=Humor,Politics/Humor`
  * Whitespace around a comma is ignored; `TAG=Humor , Politics/Humor` is the
    same as above
* Tags may only contain letters, digits, space, `_` and `-` (`TAG-03`)
  * Letters are ASCII, plus the accented letters of Latin-1 (`é`, `Ñ`, `ü`
    etc). Other Unicode is not supported
  * Whitespace around each level is quietly removed
  * Other characters are removed, with a warning: `Tag 'Fun!' renamed to 'Fun'`
  * A tag with a level left empty (eg `.`, `..` or `!!`) is ignored with a
    warning, so a tag can never reach outside the `tags` folder
* Reserved tags, ignored with a warning (in any case, and with anything below
  them):
  * `Date`, for automatic date tags (`TAG-02`)
  * `Untagged`, for images with no other tags (`TAG-03`). `TAG=Untagged` warns
    that to remove all tags from an image, use `UNTAG=*`. Other tags in the same
    value are still applied
* A new image given no tags is tagged `Untagged`; giving an image any tag
  removes its `Untagged` tag (`TAG-03`)
* `TAG=` (empty) applies no tags: earlier tags are kept, and only a new image
  becomes `Untagged`
* Tagging an image results in a symlink being placed in the relevant tag folder,
  pointing by relative path to the image in `images`
  * Given `TAG=Animal/Dog` to image `f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * Linked at: `tags/Animal/Dog/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * Symlink target: `../../../images/f1/d2/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
 
### UNTAG

* ALIAS: `UNTAGS`

Removes tags from images already in the library. Values are written as for
`TAG`

* Can't be set in configuration files, as for `TAG`
* The URI must identify a stored image without downloading: a hash, a URL
  recorded as a source, or a local file identical to a stored image (see
  `REQ-11`). Anything else is `NOTSTORED`, and nothing is added
  * `sil UNTAG=Humor https://example.com/funny.jpg`
* Only the named tag is removed; tags below it are kept. `UNTAG=Animal` leaves
  `Animal/Dog`
* `UNTAG=*` removes all of the image's tags, except its date tag. Quote it on
  the command line: `sil UNTAG='*' <uri>`
* A tag the image doesn't have is reported, and isn't a failure
* An image left with no tags is quietly tagged `Untagged` (`TAG-03`)
* `Date` and `Untagged` tags can't be removed (`TAG-02`, `TAG-03`); they are
  ignored with a warning
* `TAG` may be given too, to retag in one step: `sil TAG=New UNTAG=Old <uri>`.
  `UNTAG` is applied first, so `sil TAG=New UNTAG='*' <uri>` replaces every tag
  with `New`
* Tag folders left empty are removed

### REMOVE

* Default: off
* Flag parameter

Removes images from the library. The URI must identify a stored image, as for
`UNTAG`; anything else is `NOTSTORED`

* `sil REMOVE <hash>` (the full 40 character hash), or
  `sil REMOVE https://example.com/funny.jpg`
* Removes the stored file, every tag link to it (including its date tag), and
  its lines in the fingerprint index and sources file. Reported as `REMOVED`
* Its sources are forgotten: adding the same URL later adds the image again
* Can't be set in configuration files. In a manifest it applies, like any
  parameter, to every URI after it until set off with `REMOVE=off`
* `TAG` and `UNTAG` are not applied to removed images
* A library under git keeps the removed image in its history (`REQ-10`)

### LINK

The LINK parameter will set a symlink in the tag structure. This is designed to
effectively allow "alias tags" that will share a common folder of image symlinks

* Can't be set in configuration files: it is a one-time action on the tag
  folders rather than a setting
* Carried out once: on the command line, before any URIs; in a manifest, at its
  line (`REQ-06`). Only one `LINK` can be given on a command line; a manifest
  may have several
* The format of the value is `SOURCE -> TARGET`, one tag each, written as for
  `TAG` (case-insensitive, `/` or `:` between levels)
  * `LINK=Politics -> Meme/Politics` will create symlink at `tags/Politics` that
    points to `tags/Meme/Politics`
  * The target is created if needed
* If a folder already exists at SOURCE:
  * If no files are in the folder, the folder is removed and the symlink is created
  * If files exist, the user is warned "Source tag '$SOURCE' has images present
    - move images to '$TARGET' and replace with symlink? [Y/N]"
    * The question is asked at the terminal, and SIL waits for an answer, even
      within a manifest. With no terminal, SIL halts and nothing is changed
    * If `N`, halt and inform user that no operation occurred
    * If `Y`, relocate symlinks in SOURCE to TARGET, keeping subfolders (eg
      `Politics/Local` to `Meme/Politics/Local`), remove now-empty source
      folder, and create new symlink from SOURCE to TARGET
* If SOURCE is already a link, it is pointed at the new TARGET; if it already
  points there, nothing changes
* Refused, with a warning: a SOURCE inside its TARGET or the reverse (the link
  would loop), and a SOURCE or TARGET in the reserved `Date` or `Untagged`
  tags

## SHRINK

* Default: `0` (off)
* Size parameter

Target file size for ingested images. Images that are large enough are
re-encoded as JPEG to approximately this size (see `REQ-07`)

* Sizes are case-insensitive and 1024-based. A bare number is kilobytes
  * `500`, `500k`, `500kb` and `500KB` are all 500 KB
  * `2mb`, `2M`, `1.5mb`, `1g`, `800b` are also accepted
* `SHRINK=0` turns shrinking off, eg to override a `SHRINK` set in a
  configuration file
* Applies to still images only. Animations are shrunk by `SHRINKVID`
* Requires ImageMagick and findimagedupes. If either is missing, SIL halts with
  the command to install it

### SHRINKTRIGGER

* Default: `2`
* Number parameter (positive, decimals allowed)

How large, as a multiple of `SHRINK`, an image must be before shrinking is
attempted

* With `SHRINK=100kb` and `SHRINKTRIGGER=2`, only images of 200 KB or more are
  shrunk
* Avoids re-encoding images that are already near the target, which would cost
  quality for little saving

### SHRINKMINSAVE

* Default: `25%`
* Percent parameter

The minimum saving a shrunk image must achieve to be kept. Otherwise the
original is kept

* An 800 KB original shrunk to 600 KB saved 25%; with `SHRINKMINSAVE=30` the
  original would be kept
* Applies to both `SHRINK` and `SHRINKVID`

### FLATTEN

* Default: off
* Flag parameter

Allows images with transparency to be shrunk, by placing them on a white
background before conversion to JPEG

* Only applies when an image is being shrunk (see `SHRINK`). With `SHRINK` off,
  or an image under the trigger size, `FLATTEN` does nothing
* Without `FLATTEN`, images with transparency are never shrunk
* The shrunk image is checked against the flattened image rather than the
  transparent original, since flattening is an intended change that can alter
  the fingerprint (eg a logo on a transparent background)
* Does not apply to animations: `SHRINKVID` always places them on white

### SHRINKVID

* Default: `OFF`
* Level parameter: `HIGH` (alias `HI`, `H`), `MEDIUM` (`MED`, `M`), `LOW`
  (`LO`, `L`), or `OFF` (`0`, `NO`, `FALSE`). Any case

Shrinks animated GIF and WebP images by re-encoding them as animated AVIF
(AV1), an open, royalty-free format (see `REQ-07`)

* The level sets the AV1 quality (ffmpeg libaom `-crf`; lower is better).
  Measured on seven sample animations from 19 KB to 100 MB, the AVIF was:

  | Level    | crf | Size, as % of the original GIF |
  | -------- | --- | ------------------------------ |
  | `HIGH`   | 20  | 4-60%                          |
  | `MEDIUM` | 30  | 2-45%                          |
  | `LOW`    | 40  | 1-30%                          |

  Even `LOW` kept very good fidelity to the original
* Independent of `SHRINK`: either may be set without the other. `SHRINKTRIGGER`
  does not apply, as there is no target size; `SHRINKMINSAVE` does
* Transparency is lost: frames are placed on a white background, with a warning
* Animations already in other formats (eg AVIF) are left unchanged
* Requires ffmpeg, ImageMagick and findimagedupes. If any is missing, SIL halts
  with the command to install it
* Animated AVIF plays in current browsers (Chrome, Edge, Firefox, Safari 16.4+).
  Some desktop image viewers show only its first frame

## REFETCH

* Default: off
* Flag parameter

Download URLs again even when they are already recorded as a source

* Off: a URL already in `images/sources.txt` for a stored image is a `DUPE` of
  that image without being downloaded. Tags are still applied to it. This saves
  time and bandwidth, and avoids repeat requests that might trigger
  `RATELIMIT`, eg over Tor
* On: every URL is downloaded and checked by fingerprint, eg if a site may now
  serve a different image at the same address
* Local files are always checked by fingerprint: they are recorded by name
  only, so two different files with the same name would be confused

## THRESHOLD

* Default: `90%`
* Percent parameter

Similarity at which two images are considered duplicates (see `REQ-05`)

* Value is a percentage, passed to `findimagedupes --threshold`
* Does not affect the fixed 95% check that a shrunk image still matches its
  original (see `REQ-07`)
* Higher values require images to be more alike before being called duplicates.
  Near-identical images such as memes from one template may need a high value
  (eg `98%`) to be kept as distinct images

## CHECK

* Flag parameter; an action, so can't be set in configuration files

Checks the library for problems and reports them, without changing anything
(see `REQ-09`). `sil` exits with status 1 if any are found

* `sil CHECK` from within a library, or `sil LIBRARY=~/Pictures/sil CHECK`

## REBUILD

* Flag parameter; an action, so can't be set in configuration files

Repairs the library from its stored images (see `REQ-09`), keeping tags wherever
possible: restores missing library files, renames images whose content or place
no longer matches their name, updates their tag links, and regenerates the
fingerprint index (`images/fingerprints.txt`)

* Use after `CHECK` reports problems, after editing or adding files in `images`
  by hand, or after a `git pull` (`REQ-10`)
* Fingerprints every stored image, so takes a while on a large library
* If combined with `CHECK`, the rebuild runs first

## TOR

* ALIAS: `USETOR`
* Flag parameter

Indicates that `torsocks` should be used to recover a remote URI

* Will be ignored for local files or image hashes
* Will halt and provide instruction to user on installing `torsocks` if it is
  not available