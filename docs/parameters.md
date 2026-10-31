# Recognized parameters

This file describes the parameters recognized by SIL.

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
  * Flags can be unset by passing a zero value, eg `TOR=0`
* Multiple parameters can be separated by spaces
  * `sil TAG=Meme TOR https://example.com/funny.jpg`
* Parameter values can be quoted if they have special characters. The quotes can
  optionally include the parameter name as well.
  * `sil TAG='Meme/Politics' https://example.com/funny.jpg`
  * `sil 'TAG=Meme/Politics' https://example.com/funny.jpg`

## LIBRARY

The library parameter specifies the file path to the image library

* If specified but the folder does not exist, the folder will be created and
  subdirectories `images` and `tags` added to it
* If not specified, SIL will determine if the current folder is part of a library
  * Confirmation is based on the presence of `images` and `tags` folder
* If `LIBRARY` can not be determined, an error will be thrown and instructions
  for specifying or creating a new library will be reported.

## TAG

* ALIAS: `TAGS`

The tag parameter defines one or more tags within the library

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
* Multiple tags can be passed separated by commas
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

## RESIZE



## TOR

* ALIAS: `USETOR`
* Flag parameter

Indicates that `torsocks` should be used to recover a remote URI

* Will be ignored for local files or image hashes
* Will halt and provide instruction to user on installing `torsocks` if it is
  not available