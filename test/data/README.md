# Test data

Sample images for developing and testing SIL. `make test` does not scan this
folder; tests reference files here explicitly.

## Folders

| Path           | In git? | Contents                                         |
| -------------- | ------- | ------------------------------------------------ |
| `images/`      | Yes     | Image files we may redistribute (see below)      |
| `local/`       | No      | Image files we may not redistribute              |
| `manifest.txt` | Yes     | Test manifest, with the expected outcome of each URI. Run by hand, as it needs network access; `make test` doesn't use it |

The deciding question is whether the file may be published in this repository:

* `images/`: images generated for testing, your own photos, public domain, or
  openly licensed (eg CC0, CC BY, CC BY-SA). Record the license and any
  required attribution in the catalog
* `local/`: anything else - memes, screenshots, copyrighted images. Fine to test
  with on your own machine, but not to publish

Remote images need no file at all: list their URLs in a manifest. Linking to an
image is not redistributing it, so remote URLs need not be openly licensed,
though stable ones (eg Wikimedia Commons) make for reliable tests.

Keep committed images small (ideally under 500 KB) so the repository stays
light. Tests that need large images can generate them with ImageMagick, as
`test/shrink.bats` does.

Tests that use `local/` must skip when the file is missing, since it only exists
on the machine where it was downloaded:

```bash
[[ -f "$PROJECT_ROOT/test/data/local/meme-blank.jpg" ]] || skip "local test image missing"
```

## Naming

Name files after the trait being tested, not their subject, eg
`transparent.png` rather than `logo.png`. Near-duplicate sets share a prefix:
`cat.jpg`, `cat-resized.jpg`, `cat-cropped.jpg`.

## Wanted

Useful traits for upcoming work (adding images, shrinking, duplicates, REQ-08):

* Large JPEG photo (over 1 MB) - shrinking
* PNG photo without transparency - shrinking and conversion to JPEG
* PNG with an `iCCP: known incorrect sRGB profile` flaw - fingerprinting strips
  profiles because of this flaw, and no test has one yet
* Near-duplicates of one image: resized, recompressed, lightly cropped,
  watermarked - fingerprint `THRESHOLD`
* Meme variants from one template (see `sampleManifest.txt`) - high similarity
  that should still be kept distinct
* JPEG with EXIF rotation - orientation through shrinking
* A non-image saved with an image suffix, eg an HTML page as `.jpg` -
  REQ-08 "unexpected result"

## Catalog

Record every file here, in either folder. For `local/` files the source URL lets
anyone re-download them.

| File | Folder | Trait | Source | License |
| ---- | ------ | ----- | ------ | ------- |
| `plasma.png` | images | Opaque PNG, 320x240, ~400 KB; shrinkable | Generated: `convert -size 320x240 -seed 11 plasma:fractal` | CC0 |
| `transparent.png` | images | PNG with 60% alpha | Generated: plasma, seed 12, alpha 60% | CC0 |
| `animated.gif` | images | 2-frame animated GIF | Generated: plasma, seeds 13 and 14 | CC0 |
| `not-an-image.jpg` | images | HTML "login required" page with a `.jpg` suffix | Hand written | CC0 |
