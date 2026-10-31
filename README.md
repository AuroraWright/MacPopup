# MacPopup

A native macOS overlay that shows text received over WebSockets (like
[texthooker-ui](https://github.com/Renji-XD/texthooker-ui)) in a floating box above every window,
including fullscreen apps, and lets you hover words to get a Yomitan-style dictionary popup with
Anki card creation. Lookups come from your installed Yomitan through the
[Yomitan API](https://github.com/yomidevs/yomitan-api).

## Requirements

- macOS 14 or later, Swift 5.9+ (Xcode or the command line tools), Node.js 18+
- Yomitan with the Yomitan API native host set up (default `http://127.0.0.1:19633`)
- AnkiConnect for card creation (default `http://127.0.0.1:8765`)

## Build and run

```sh
cd web && npm install && cd ..
scripts/build.sh            # release build → build/MacPopup.app
open build/MacPopup.app
```

`scripts/build.sh debug` makes a debug build. The first build downloads Yomitan's kanji stroke
order font into `build/cache`.

The app has no Dock icon. Use the menu bar item (speech bubble) for Settings, hiding the overlay,
moving it to another display, reloading, and quitting.

## Usage

- Text arrives from each WebSocket URL in Settings → Connection (default `ws://localhost:6677`).
  Plain text and texthooker JSON (`{"sentence": "..."}`) messages are both accepted.
- Drag the box by its header and resize it from the bottom right corner. Its position is saved.
- Hover a word to look it up. Settings → Scanning sets the modifier key (none by default).
- Inside a popup, hold Shift (configurable) and hover to open a nested popup.
- For combinations or mouse buttons, choose **Custom…** as the scan modifier. You can then record
  or type a list of inputs, like Yomitan's scan inputs, and any one of them triggers scanning. As
  in Yomitan, an entry combines the modifier keys `meta`, `ctrl`, `alt` and `shift` with mouse
  buttons numbered like Yomitan's: `mouse0` left, `mouse1` right, `mouse2` middle, `mouse3` back,
  `mouse4` forward, `mouse5`. Examples: `meta`, `mouse3`, `mouse1 mouse2`, `ctrl mouse0`.
- Clicking anywhere outside the popups closes them.
- The header buttons pause new lines, clear lines, open Settings and hide the overlay.

The buttons at the top of Settings import existing settings:

- **Import Yomitan** reads a Yomitan settings export (Yomitan Settings → Backup → Export
  Settings). If the export has several profiles, you pick one. It copies the popup appearance and
  position, custom popup CSS, each dictionary's own styles, scan length, delay and modifier,
  sentence parsing, audio auto-play, the Anki connection, tags, duplicate and screenshot options,
  and the Anki field templates.
- **Import texthooker-ui** reads a texthooker-ui settings export, so your theme, font size,
  replacements and so on carry over.

## Yomitan popup

The popup uses Yomitan's own display code, templates and CSS, so it looks and behaves like the
extension's popup: dictionary entries, tags, frequencies, pitch accents, inflection info, kanji
entries, audio and history navigation.

Popup options that live in Yomitan's settings, such as theme, scale, size, position, custom CSS
and the styles that come with dictionaries, can't be read through the Yomitan API. MacPopup has its own copies of them in Settings → Popup.
Use **Import Yomitan** to copy them over, or set them by hand.

## Anki

Card formats (deck, note type, field templates) and field values come from the selected Yomitan
profile through the API, so they match what the extension would create. MacPopup fills in the
markers the API can't know about from the overlay itself:

- `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}`,
  `{sentence-furigana-plain}`: from the line you looked up
- `{document-title}`: the name of the frontmost app
- `{screenshot}`: the display the overlay is on, without the overlay. This needs Screen Recording
  permission (System Settings → Privacy & Security).
- `{clipboard-text}`, `{clipboard-image}`, `{popup-selection-text}`

Templates can also read text selected in the popup (`getMedia "popupSelectionText"`), for example
to pick a dictionary by selecting its name. The API can't see the selection, so for this turn on
Settings → Anki → **Render the field templates below instead of using the Yomitan API**. MacPopup
then renders the fields itself with Yomitan's renderer and the field templates shown in Settings,
which **Import Yomitan** copies from your profile. Edit them there, or import again after changing
them in Yomitan.

Duplicate checks, "add duplicate", overwrite and "view note" work as they do in Yomitan, based on
the duplicate settings in Settings → Anki.

## Limitations

- The overlay never takes keyboard focus, so Yomitan's keyboard shortcuts aren't available. Use the
  mouse for everything.
- Because WebKit only sends hover events to the focused window, CSS `:hover` effects (such as
  button highlights) only show while MacPopup is the active app. Lookups and nested lookups don't
  depend on this.
- Scanning works on the overlay's own text, not on other apps.

## License

GPL-3.0, because it includes code from [Yomitan](https://github.com/yomidevs/yomitan) (see
`vendor/yomitan/README.md` for the commit). See `LICENSE`.
