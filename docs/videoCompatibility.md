# Animated media compatibility in chat and social tools

SIL stores animations as AVIF, which gives the best quality for the size.
Many chat tools reject AVIF or show it as a still image. This page records
which formats each tool accepts, so that an export from SIL can pick a
format the destination will play.

The grid was compiled in **November 2026**, mostly from third-party guides
and forum reports, with official vendor documentation where available
(see [Sources](#sources)). These tools change often, and many cells are
unverified. Treat `?` and any cell marked † as needing a test (see
[Verifying a cell](#verifying-a-cell)).

## Formats

Every format below can be created and read with FOSS tools in Ubuntu's
repositories.

| Column | Container / codec | Encode with | Notes |
| ------ | ----------------- | ----------- | ----- |
| **GIF** | GIF89a | `ffmpeg` (`palettegen`/`paletteuse`), `gifski`† | 256 colours per frame, large files. Supported almost everywhere, but often converted to MP4 on upload |
| **WebP** | Animated WebP | `img2webp`, `gif2webp` (`webp`), `ffmpeg -c:v libwebp_anim` | 24-bit colour plus alpha. Widely accepted as an image, but often shown as a still |
| **AVIF** | Animated AVIF (AV1 image sequence) | `avifenc` (`libavif-bin`), `ffmpeg -c:v libsvtav1 -f avif` | SIL's storage format. Best compression of the image formats, and the least supported |
| **APNG** | Animated PNG | `ffmpeg -f apng`, `apngasm` | Lossless, large files. Rarely recognised as animated |
| **MP4<br>H.264** | MP4 + H.264 (`yuv420p`) + AAC | `ffmpeg -c:v libx264` | **The universal fallback.** Use `-pix_fmt yuv420p -movflags +faststart` |
| **MP4<br>HEVC** | MP4 + H.265 | `ffmpeg -c:v libx265` | Better compression than H.264. Patent-encumbered, and plays only where the device has a decoder |
| **AV1 video** | MP4 or WebM + AV1 | `ffmpeg -c:v libsvtav1` / `libaom-av1`; decode `dav1d` | The same codec as AVIF, in a video container. Plays in browsers, but chat apps support it unevenly |
| **WebM<br>VP9** | WebM + VP9 (+ Opus) | `ffmpeg -c:v libvpx-vp9` | Royalty-free, with alpha support. Plays in every browser |
| **MOV<br>H.264** | QuickTime + H.264 | `ffmpeg -c:v libx264 -f mov` | The same codec as MP4<br>H.264. Listed only because some tools accept `.mov` but not `.webm` |
| **OGV<br>Theora** | Ogg + Theora (+ Vorbis) | `ffmpeg -c:v libtheora` (`.ogv`) | Royalty-free, but older and less efficient than VP9. Chrome (123) and Firefox (2024) removed Theora decoding, so browser-based clients can't play it inline |
| **MPEG<br>MPEG-2** | MPEG program stream + MPEG-2 (or MPEG-1) | `ffmpeg -c:v mpeg2video -f vob` (`.mpg`) | Patents expired; ffmpeg's encoder is built in. Needs a constant, standard frame rate (eg `-vf fps=30`). Large files, and no browser decodes it |

† `gifski` produces noticeably better GIFs than ffmpeg alone. I believe it
is in the Ubuntu universe repository, but that hasn't been confirmed.

## Grid

Each cell shows what a recipient sees when the file is uploaded as an
attachment. Pasting from the clipboard is a separate question: it usually
sends a single still image, whatever the format.

| Symbol | Meaning |
| ------ | ------- |
| ✅ | Accepted and plays inline |
| 🔄 | Accepted but converted on upload (eg GIF → silent MP4). Plays, at the service's quality |
| 🖼 | Accepted, but shown as a still image (or animation not confirmed) |
| 📎 | Accepted only as a file to download, with no inline player |
| ⚠️ | Depends on the device or decoder, or reports conflict |
| ❌ | Rejected |
| ? | Not found in sources; needs a test |

| Tool | GIF | WebP | AVIF | APNG | MP4<br>H.264 | MP4<br>HEVC | AV1 video | WebM<br>VP9 | MOV<br>H.264 | OGV<br>Theora | MPEG<br>MPEG-2 |
| ---- | :-: | :--: | :--: | :--: | :-------: | :------: | :-------: | :------: | :-------: | :----: | :----: |
| **Discord** | ✅ | ✅ | ✅ | ? | ✅ | ⚠️ | ⚠️ | ✅ | ✅ | 📎‡ | 📎‡ |
| **Slack** | ✅† | ? | ? | ? | ✅ | 🔄† | 🔄† | 🔄† | ✅ | ? | ? |
| **Microsoft Teams** | ✅ ⚠️ | 🖼† | ? | ? | ✅ | ? | ? | ? | ✅ | ? | ? |
| **Webex** | ✅ ≤ 2 MB | ? | ? | ? | ✅† | ? | ? | ? | ✅† | ? | ✅† |
| **Steam chat** | ? | ? | ? | ? | ⚠️ | ? | ? | ✅† | ? | ✅† | ✅† |
| **X (Twitter)** | 🔄 | 🖼 | ? | ? | ✅ | ❌ | ? | ? | ✅ | ? | ? |
| **Bluesky** | 🔄 | 🖼 | ? | ? | ✅ | ? | ? | ✅ | ✅ | ? | ✅† |
| **Mastodon** | 🔄 | 🖼 | 🖼 | ? | ✅ | ? | ? | ✅ | ✅ | ? | ? |
| **Reddit** | 🔄 | ? | ? | ? | ✅ | ? | ? | ? | ✅ | ? | ? |
| **Telegram** | 🔄 | 🖼 | ? | ? | ✅ | ? | ? | ✅† | ? | ? | ? |
| **WhatsApp** | 🔄† | 🖼 | ? | ? | ✅ | ❌ | ? | ? | ⚠️ | ? | ? |
| **Matrix (Element)** | ✅ | ✅† | 🖼 | ✅† | ✅† | ⚠️ | ⚠️ | ✅† | ? | 📎‡ | 📎‡ |
| **Signal** | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **Google Chat** | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| ~~Skype~~ | — | — | — | — | — | — | — | — | — | — | — |

† Single or weak source; see the notes below.
‡ Inferred, not tested: the client is browser-based (Chromium or web), and
current browsers don't decode this format.

### Notes by tool

* **Discord:** Discord's engineering blog confirms animated WebP and AVIF in
  attachments and embeds. Mobile support arrived in late 2024, and animated
  emoji uploads in May 2025. HEVC and AV1 play only where the device has a
  decoder, and a black player is a common symptom of a missing one. The free
  upload cap is reported as 10 MB in older sources and 20 MB in newer ones.
* **Slack:** Slack's official account said in 2018 that the inline player was
  MP4-only. A 2026 third-party test found MP4, MOV, WebM and MKV all play
  inline, apparently because Slack transcodes them to H.264. It found that
  AVI downloads only. GIF inline playback is long-standing behaviour, but no
  current source in this search covered it.
* **Microsoft Teams:** Video previews go through OneDrive. Uploading a GIF
  through the attachment control animates. Pasting one often sends a still
  frame. A 2020 report says WebP had no preview; this may have changed.
  Tenant admins can turn off GIFs and previews.
* **Webex:** Webex's help lists `.gif .mp4 .mov .mpg .wmv` among supported
  file types (`.mpg` is the MPEG column), and says GIFs autoplay when
  under 2 MB. It doesn't say whether
  MP4 gets an inline player.
* **Steam chat:** There is no official documentation. A forum thread reports
  that WebM became accepted while MP4 broke after a chat update. The
  Steamworks store-asset docs (a different feature) list GIF, WebP, MP4 and
  WebM. The maintainer observed in November 2026 that chat accepts OGV,
  WebM and MPEG files; whether each plays inline hasn't been checked.
* **X (Twitter):** Spec sites agree on MP4 and MOV with H.264 and AAC, and
  one says H.265 is rejected at upload. GIFs become silent MP4 loops. WebP is
  accepted as an image, and one source says animated images show only the
  first frame.
* **Bluesky:** Video formats are MP4, MPEG, WebM and MOV (Bluesky
  re-encodes uploads, so MPEG should play). GIFs are converted
  to a silent looping video. Images can be JPEG, PNG, GIF or WebP, and AVIF
  is not listed.
* **Mastodon:** Images can be JPEG, PNG, GIF, WebP, HEIF or AVIF. Videos can
  be MP4, M4V, WebM or MOV. Uploaded GIFs become silent MP4s ("GIFV"), and
  older versions transcoded video to H.264. Each instance sets its own size
  limits.
* **Reddit:** Images can be PNG, JPEG or GIF, and videos MP4 or MOV
  (H.264). GIFs are served as MP4.
* **Telegram:** GIFs become silent H.264 MP4s on the server. Video stickers
  are VP9 WebM with alpha, and static stickers are WebP.
* **WhatsApp:** H.264 and AAC in MP4 is the only reliable video format. The
  Business API rejects GIF, and HEVC is reported to fail silently. The app
  converts GIFs to MP4 itself. The video limit is 16 MB.
* **Matrix (Element):** The web client plays whatever the browser can play,
  so WebM and MP4 usually work. The Element Web changelog notes sending and
  thumbnailing AVIF, improved animated GIF and WebP handling, and APNG
  support. Whether animated AVIF plays is untested.
* **Skype:** Retired 5 May 2025. Users moved to Teams Free, which behaves
  like the Teams row.
* **Signal, Google Chat:** No sources found in this pass.

## Takeaways

1. **MP4 with H.264 (`yuv420p`, `+faststart`) is the only format accepted
   everywhere.** Most services convert GIF to MP4 anyway, so exporting MP4
   directly skips their re-encode and the 256-colour step.
2. **GIF is the fallback for image-only destinations:** email, forums,
   Webex under 2 MB, and places where video uploads are disabled.
3. **WebM/VP9 is the best FOSS option** where it's accepted (Discord,
   Bluesky, Mastodon, Matrix, Steam). It gives smaller files than H.264 and
   has no patent concerns.
4. **OGV and MPEG are only worth exporting for tools that reject the
   alternatives**, which Steam chat seemed to do for MP4 at one point.
   In `~/ToFile/TestImages/compare.html`, both came out larger than VP9 WebM
   at their highest settings (Theora by 1.1–1.7×, MPEG-2 by 2–4.5×, and
   more for very small clips), and browser-based clients
   can't play either inline.
5. **AVIF and AV1 video should stay as the stored format.** Of the chat
   tools here, only Discord has documented support.

Suggested export set for SIL: **MP4/H.264** by default, with **GIF** and
**WebM/VP9** as options. ffmpeg 6.1 in Ubuntu already decodes SIL's
animated AVIF, so all three need only ffmpeg (plus gifski, optionally, for
better GIFs).

## Verifying a cell

To fill in a `?`, send a test set to a private channel or to yourself.
Generate the set from one animated AVIF in the library:

```bash
src=sample.avif
ffmpeg -i "$src" -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" t.gif
ffmpeg -i "$src" -c:v libwebp_anim -lossless 0 -q:v 80 -loop 0 t.webp
ffmpeg -i "$src" -f apng -plays 0 t.png
ffmpeg -i "$src" -c:v libx264 -pix_fmt yuv420p -movflags +faststart t_h264.mp4
ffmpeg -i "$src" -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 t_hevc.mp4
ffmpeg -i "$src" -c:v libsvtav1 t_av1.mp4
ffmpeg -i "$src" -c:v libvpx-vp9 -b:v 0 -crf 32 t_vp9.webm
ffmpeg -i "$src" -c:v libx264 -pix_fmt yuv420p t_h264.mov
ffmpeg -i "$src" -c:v libtheora -q:v 7 t.ogv
ffmpeg -i "$src" -vf fps=30 -c:v mpeg2video -q:v 3 -bf 2 -f vob t.mpg
cp "$src" t.avif
```

Some sources give odd frame dimensions. If libx264 refuses the input, add
`-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2"`. Record the result, the date and
the client (desktop, web, iOS or Android) in the grid, since clients often
differ.

## Sources

* [Discord: Modern image formats at Discord (WebP and AVIF)](https://discord.com/blog/modern-image-formats-at-discord-supporting-webp-and-avif)
* [Discord May 2025 update: WebP/AVIF emoji](https://www.thetechoutlook.com/news/apps/discord-may-1-update-adds-webp-avif-emoji-uploads-multi-image-ios-embeds-android-video-speed-boost-and-over-60-bug-fixes/)
* [Discord video specs (allplatforms.io)](https://allplatforms.io/discord/)
* [Discord video won't play: causes (8mb.video)](https://8mb.video/discord-video-not-playing)
* [Discord video limits 2026 (vid-crush)](https://vid-crush.com/blog/discord-video-limits/)
* [Slack: inline player MP4 only (2018)](https://x.com/SlackHQ/status/1024410928085970945)
* [Slack video formats, tested (slack.green)](https://slack.green/en/blog/slack-video-formats)
* [Slack file object types](https://docs.slack.dev/reference/objects/file-object/)
* [Teams: sharing video via OneDrive (WinXDVD)](https://www.winxdvd.com/streaming-video/how-to-share-video-on-microsoft-teams.htm)
* [Teams: custom animated GIF in chat (Microsoft Q&A)](https://learn.microsoft.com/en-us/answers/questions/4379856/unable-to-insert-custom-made-animated-gif-in-chat)
* [Teams quick tip: GIFs and WebP (2019/2020 comments)](https://itspartlycloudy.com/2019/01/11/microsoft-teams-quick-tip-4-the-perfect-gif-doesnt-exist/)
* [Webex App: share files with others](https://help.webex.com/article/yuwad5/Webex-App-|-Share-files-with-others)
* [Steam forum: MP4 missing from chat update](https://steamcommunity.com/discussions/forum/1/2961669453613421073/)
* [Steamworks: store page asset formats](https://partner.steamgames.com/doc/store/page/assets)
* [X video specs (vidulk)](https://www.vidulk.com/video-specs/x-twitter)
* [X image sizes (postinstantly)](https://postinstantly.com/sizes/x-image-sizes)
* [Bluesky video formats (BskySaver)](https://bskysaver.com/blog/bluesky-video-formats-and-quality)
* [Bluesky content guidelines (OnlySocial)](https://onlysocial.io/bluesky-content-guidelines/)
* [Mastodon media upload limits (Guérilla.Studio)](https://guerilla.studio/blog/mastodon-media-upload-limits/)
* [fedi.tips: posting images, video and GIFs](https://fedi.tips/how-do-i-post-images-videos-or-audio-in-mastodon-what-can-i-attach-to-a-post-how-do-i-post-gifs/)
* [Reddit media limits (Postpone)](https://help.postpone.app/platforms/reddit/media-limits)
* [Telegram: GIFs arrive as silent MP4](https://whatthegif.com/guides/gif-for-telegram)
* [WhatsApp supported media (AWS)](https://docs.aws.amazon.com/social-messaging/latest/userguide/supported-media-types.html)
* [WhatsApp API media formats (WhatChimp)](https://help.whatchimp.com/docs/whatsapp-business-api/whatsapp-api-maximum-media-size-supported-formats)
* [Element Web v1.10.9 changelog](https://gitlab.com/yhm-amber/element-web/-/tags/v1.10.9)
* [Ogg/Theora browser support (caniuse)](https://caniuse.com/ogv)
* [Chrome dropping Theora (Phoronix)](https://Phoronix.com/news/Google-Chrome-Dropping-Theora)
* [Skype retirement (Microsoft Support)](https://support.microsoft.com/en-gb/skype)
