# MacPopup

A native macOS overlay that shows text received over WebSockets (like
[texthooker-ui](https://github.com/Renji-XD/texthooker-ui)) in a floating box above every window,
including fullscreen apps, and lets you hover words to get a Yomitan-style dictionary popup with
Anki card creation. Lookups come from your installed Yomitan through the
[Yomitan API](https://github.com/yomidevs/yomitan-api).

In screen OCR mode, MacPopup instead reads another app's window (a game, say) with Apple's Live
Text and lets you hover the window's own text, with no text box at all.

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

The app has no Dock icon. Use the menu bar item (speech bubble) for Settings, screen OCR mode,
hiding the overlay, moving it to another display, reloading, and quitting.

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

## Screen OCR mode

Turn it on with **Screen OCR Mode** in the menu bar. The text box disappears, and words in the
chosen window open popups when hovered, the same way as in the box. MacPopup needs the Screen
Recording permission (System Settings → Privacy & Security), which macOS asks for the first time.

- **Select Window for OCR…** (also in Settings → Screen OCR) covers the screen: click the window to
  read, then optionally drag over the parts that show text, such as the game's text box, and click
  **Done** (or press Return). Without areas, the whole window is read. **Undo** (Delete) removes the
  last area or goes back to choosing the window, and **Cancel** (Esc) keeps the previous choice.
  The window is found again by its app and title the next time MacPopup starts.
- Text is recognized with Live Text in the language set in Settings → Screen OCR (Japanese by
  default), horizontal or vertical. Only the chosen areas are captured, and a window drawn at 1x
  (e.g. a VM or a game that isn't Retina aware) is read at 1x, which is faster ("Read at" in
  Settings overrides this).
- Without a WebSocket, MacPopup watches the window (or the chosen areas) and reads it again when
  more than the change threshold of it changes and then stays still. Small changes like a blinking
  cursor stay under the threshold. Choosing areas helps with animated backgrounds. To save work,
  with "Watch after mouse use" (on by default) this only happens for a while (2 seconds) after the
  mouse moves or clicks (e.g. a click that advances the text), and the window is checked right away
  when it starts being used. Words are looked up when the cursor moves (or a scan key is
  pressed), not when new text appears under a resting cursor.
- The window is only read while it's on screen in the current space; it's read again when it comes
  back, and lines that arrive meanwhile are read then.
- With a WebSocket connected, each new line is the cue to read the window instead, and the window
  is only watched for changes for a moment after each reading. Hooks usually send the line as the
  game starts drawing it, so MacPopup waits until the window stops changing before reading, and
  hides the previous text meanwhile. Recognized text that matches the line is
  corrected with it (the WebSocket text wins), and if it doesn't match yet, the window is read
  again. Turn this off with **Use WebSocket lines**.
- Words are only looked up while no other window covers the chosen one at the cursor.
- **Outline recognized text** in Settings is for debugging: it shows what was recognized, red for
  plain OCR text, green for lines corrected with the WebSocket line.

Live Text is read through a private VisionKit interface (the same one owocr uses), so a future
macOS version could change it.

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
- Outside screen OCR mode, scanning works on the overlay's own text, not on other apps.

## License

GPL-3.0, because it includes code from [Yomitan](https://github.com/yomidevs/yomitan) (see
`vendor/yomitan/README.md` for the commit). See `LICENSE`.
