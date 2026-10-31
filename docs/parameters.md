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

## Configuration files

Parameters can be stored in two `PARAM=VALUE` files (see `REQ-02` for
precedence). Blank lines and lines starting with `#` are ignored.

Configuration files hold settings that apply broadly. Some parameters can't be
set in them; SIL warns and ignores those lines:

* `TAG` and `LINK` - in neither file. They apply to individual images or are
  one-time actions; use the command line or a manifest
* `LIBRARY` - in `~/.sil.conf` only, as a default library

| File                  | Hidden | Scope                                     |
| --------------------- | ------ | ----------------------------------------- |
| `~/.sil.conf`         | Yes    | User's global defaults, in `$HOME`        |
| `<LIBRARY>/sil.conf`  | No     | One library; created from `templates/sil.conf` |

## LIBRARY

The library parameter specifies the file path to the image library

* Can be set in `~/.sil.conf` as a default library, but not in a library's own
  `sil.conf`, which is only read once the library is already known

* A library is a folder containing `images` and `tags` folders
* The library is chosen in this order:
  1. `LIBRARY` given on the command line
  2. The library containing the current folder. The current folder and each
     of its parents are checked, so running SIL from eg `tags/Animal/Dog`
     finds the library
  3. `LIBRARY` set in `~/.sil.conf`
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
* Tagging an image results in a symlink being placed in the relevant tag folder,
  pointing by relative path to the image in `images`
  * Given `TAG=Animal/Dog` to image `f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * Linked at: `tags/Animal/Dog/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
  * Symlink target: `../../../images/f1/d2/f1d2d2f924e986ac86fdf7b36c94bcdf32beec15.jpg`
 
### LINK

The LINK parameter will set a symlink in the tag structure. This is designed to
effectively allow "alias tags" that will share a common folder of image symlinks

* Can't be set in configuration files: it is a one-time action on the tag
  folders rather than a setting

* The format of the value is `SOURCE -> TARGET`
  * `LINK=Politics -> Meme/Politics` will create symlink at `tags/Politics` that
    points to `tags/Meme/Politics`
* If a folder already exists at SOURCE:
  * If no files are in the folder, the folder is removed and the symlink is created
  * If files exist, the user is warned "Source tag '$SOURCE' has images present
    - move images to '$TARGET' and replace with symlink? [Y/N]"
    * If `N`, halt and inform user that no operation occurred
    * If `Y`, relocate symlinks in SOURCE to TARGET, remove now-empty source
      folder, and create new symlink from SOURCE to TARGET

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

## THRESHOLD

* Default: `90%`
* Percent parameter

Similarity at which two images are considered duplicates (see `REQ-05`)

* Value is a percentage, passed to `findimagedupes --threshold`
* Does not affect the fixed 90% check that a shrunk image still matches its
  original (see `REQ-07`)
* Higher values require images to be more alike before being called duplicates.
  Near-identical images such as memes from one template may need a high value
  (eg `98%`) to be kept as distinct images

## TOR

* ALIAS: `USETOR`
* Flag parameter

Indicates that `torsocks` should be used to recover a remote URI

* Will be ignored for local files or image hashes
* Will halt and provide instruction to user on installing `torsocks` if it is
  not available