# Test data

Sample images for developing and testing SIL. `make test` does not scan this
folder; tests reference files here explicitly.

## Folders

| Folder    | In git? | Contents                                              |
| --------- | ------- | ----------------------------------------------------- |
| `images/` | Yes     | Images we may redistribute: your own photos, public domain, or openly licensed (eg CC0, CC BY) |
| `local/`  | No      | Anything else, eg memes or other images from the web  |

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
* PNG with transparency - must not be shrunk
* Animated GIF - must not be shrunk
* WebP image
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
