# Simple Image Library (SIL)

SIL is a command line tool for collecting and organizing images from the
internet and your own files. A library is nothing more than a folder of plain
files and relative symlinks: images are stored once under a name derived from
their content, and tags are ordinary folders of links to them. There is no
database or server, so a library can be browsed with any file manager or image
viewer, moved freely, and shared with git. SIL itself is written in bash on top
of standard open source tools, and aims to stay simple.

# Features

* **Multiple libraries**, each fully contained in its own folder
* **Add images** by URL (including onion addresses, and optionally any URL
  through Tor) or local file path
* **Formats**: JPEG, PNG, GIF, WebP, BMP, TIFF and AVIF images, plus MP4, WebM
  and MOV videos. The format is judged by content, never by file suffix
* **Batch loading** with manifest files, which also write a report and a
  ready-to-retry list of failures
* **Duplicate detection** by visual fingerprint, so a rescaled or converted copy
  of an image isn't stored twice, with a separate record of every source. A
  larger copy can optionally replace the stored image (`KEEPLARGER`)
* **Tags** as nested folders you can browse, with aliases (`LINK`) and
  controlled vocabularies (`REMAP`)
* **Automatic date tags**, linked from day to day, and an `Untagged` tag, so
  every image can be found
* **Shrinking** to save disk space: still images are converted to JPEG at a
  target size, and animations and videos to animated AVIF. A shrunk image is
  only kept if it still looks like the original
* **Maintenance**: `CHECK` finds problems and `REBUILD` repairs them from the
  stored images
* **Git-ready libraries**, set up so that images added by different people merge
  cleanly
* **Clear reporting**: each image gets a status or a specific reason for failure,
  and the exit status tells scripts if anything failed

# Parameters

Parameters control what SIL does. Names can be given in any case, and are written
in uppercase here. `sil --help` gives a summary; full details are in
[docs/parameters.md](docs/parameters.md).

## Configuration files, manifests and precedence

SIL reads parameters from four places. When a parameter is set in more than one,
the later source below takes precedence, and replaces the earlier value rather
than adding to it:

| Order | Source             | Location                  | Applies to                  |
| ----- | ------------------ | ------------------------- | --------------------------- |
| 1     | Global preferences | `~/.sil.conf`             | Every run                   |
| 2     | Library settings   | `<LIBRARY>/sil.conf`      | That library                |
| 3     | Command line       | After `sil`               | That run                    |
| 4     | Manifest           | Any `.txt` file passed to `sil` | Following URIs in that manifest |

* `~/.sil.conf` doesn't exist until you create it
* `sil.conf` is created with each new library, with commented-out examples to
  uncomment and edit
* Both have one `PARAM=VALUE` per line. Blank lines and lines starting with `#`
  are ignored. Parameters that aren't allowed in them (see the table below) are
  ignored with a warning

The library itself is chosen separately, as its `sil.conf` can't be read until
it is known. The first of these is used:

1. `LIBRARY` at the top of a manifest, for the URIs in that manifest
2. `LIBRARY` on the command line
3. The library containing the current folder, however deep within it
4. `LIBRARY` in `~/.sil.conf`

A folder that doesn't exist or is empty is made into a new library. A folder with
other contents is left alone, and SIL halts.

## Command line and manifests

On the command line, parameters come first, followed by any number of URIs and
manifests. A URI is a web or onion URL, a local file path, or the 40 character
hash of a stored image. Flags are given by name alone, and turned off with `0`,
`no`, `false` or `off`:

```bash
sil LIBRARY=~/Pictures/sil
sil TAG=Meme,Politics/Humor REFETCH https://example.com/funny.jpg ./local.png
sil 'LINK=Politics -> Meme/Politics'
sil SHRINK=500kb REFETCH=off manifest.txt
```

A manifest is a text file with a `.txt` suffix, with one parameter or URI per
line. Blank lines, and lines starting with `#`, are ignored. A parameter applies
to the URIs after it, and may be changed as often as needed:

```text
LIBRARY=~/Pictures/sil
SHRINK=500kb

TAG=Animal/Dog
https://example.com/dog.jpg
photos/rex.png

# Parameters can change partway through
TAG=Animal/Cat
SHRINK=0
https://example.com/cat.jpg
```

The two differ in these ways:

| | Command line | Manifest |
| ------------------- | ------------------------------- | -------------------------- |
| Quoting | Follows shell rules: quote values with spaces or special characters, eg `'LINK=A -> B'`, `UNTAG='*'` | Not needed; one pair of surrounding quotes is removed |
| Position | All parameters before the first URI | Any line; `LIBRARY` before the first URI |
| Lasts for | The whole run | The URIs after it, up to the end of the manifest. Settings are then restored |
| Repeating | The last value is used for everything | Each value applies until the next. `TAG=` and `UNTAG=` clear the earlier value |
| Relative paths | From the current folder | From the manifest's folder |
| `LINK`, `REMAP` | One of each, before any URIs | Any number, each carried out at its line |
| Unknown `NAME=VALUE` | Halts | Reported and ignored |
| Reports | On screen only | Also `<manifest>.txt.md`, and failures in `<manifest>.txt.err`, itself a manifest that can be renamed and rerun |

## All parameters

The **Where** column shows where a parameter can be set: **G** `~/.sil.conf`,
**L** a library's `sil.conf`, **C** the command line, **M** a manifest. Value
types are:

* **Size**: 1024-based, and a bare number means kilobytes, eg `500`, `500kb`,
  `1.5mb`
* **Percent**: 0-100, with or without `%`
* **Flag**: `NAME` alone or any other value is on; `0`, `no`, `false` or `off`
  is off

| Parameter | Value | Default | Where | Function |
| --------- | ----- | ------- | ----- | -------- |
| `LIBRARY` | Path | See above | G C M | The library to use. Created if needed |
| `TAG`, `TAGS` | Tags | None | C M | Tags to apply, comma separated. `/` or `:` separates levels of a hierarchy, eg `Animal/Dog`. Case-insensitive. `Date` and `Untagged` are reserved |
| `UNTAG`, `UNTAGS` | Tags | None | C M | Tags to remove from images already in the library. `*` removes all but the date tag |
| `REMOVE` | Flag | Off | C M | Remove images from the library, with their tags and records |
| `LINK` | `SOURCE -> TARGET` | None | C M | Make tag `SOURCE` a symlink to tag `TARGET`, as an alias. Asks before moving any images already in `SOURCE` |
| `REMAP` | `SOURCE -> TARGET` | None | C M | Quietly replace tag `SOURCE` with `TARGET`, for existing images and from now on. Kept in `RemappedTags.txt` in the library, which can be edited by hand |
| `SHRINK` | Size | `0` (off) | G L C M | Target size for still images, which are re-encoded as JPEG |
| `SHRINKTRIGGER` | Number | `2` | G L C M | Only shrink still images at least this many times `SHRINK` |
| `SHRINKMINSAVE` | Percent | `25%` | G L C M | Keep the original unless shrinking saves at least this much. Also applies to `SHRINKVID` |
| `SHRINKVID` | `HIGH`, `MEDIUM`, `LOW`, `OFF` | `OFF` | G L C M | Convert animated GIF and WebP images, and videos, to animated AVIF at this quality. Removes transparency and sound |
| `FLATTEN` | Flag | Off | G L C M | Allow `SHRINK` to shrink images with transparency, by placing them on white |
| `THRESHOLD` | Percent | `90%` | G L C M | How similar two images must be to count as duplicates. Use a high value, eg `98%`, to keep near-identical images apart |
| `REFETCH` | Flag | Off | G L C M | Download a URL even if it is already recorded as a source of a stored image |
| `KEEPLARGER` | Flag | Off | G L C M | When a duplicate has more pixels than the stored image, replace the stored image, keeping its tags, sources and date. Logged in `ReplacedImages.tsv`, with the old file kept in `replacedWithHigherRes/` |
| `TOR`, `USETOR` | Flag | Off | G L C M | Download through `torsocks`. Onion addresses always are |
| `CHECK` | Flag | Off | C | Report problems in the library, changing nothing. Exits with status 1 if any are found |
| `REBUILD` | Flag | Off | C | Repair the library from its stored images, keeping tags. Runs before `CHECK` if both are given |
| `STOPSIL` | Flag | Off | M | Stop reading the manifest at this line |

# Installation

SIL runs on Linux with bash, and needs no compiling. The commands below are for
Debian and Ubuntu; on Ubuntu, `findimagedupes` is in the `universe` repository.

1. Install the tools SIL uses:

   ```bash
   sudo apt install git curl file imagemagick findimagedupes ffmpeg
   ```

   To download through Tor, using `TOR` or onion addresses, also install
   `torsocks`:

   ```bash
   sudo apt install torsocks
   ```

2. Get the code, wherever you would like to keep it. SIL needs the whole folder,
   not just the `sil` script:

   ```bash
   git clone https://github.com/VCF/simpleImageLibrary.git
   ```

3. Add SIL to your `$PATH`, by linking it into a folder already on your path. On
   Ubuntu, `~/.local/bin` is added to the path at login if the folder exists, so
   you may need to log in again if you have just created it:

   ```bash
   mkdir -p ~/.local/bin
   ln -s "$PWD/simpleImageLibrary/sil" ~/.local/bin/sil
   ```

   Or add the folder itself to your path, by adding this line to `~/.bashrc`,
   using the actual location of your copy:

   ```bash
   export PATH="$PATH:$HOME/path/to/simpleImageLibrary"
   ```

4. Check that it works, and optionally set a default library, which `sil CHECK`
   below creates. Without a default, run SIL from inside a library, or give
   `LIBRARY` each time:

   ```bash
   sil --help
   echo 'LIBRARY=~/Pictures/sil' >> ~/.sil.conf
   sil CHECK
   ```
