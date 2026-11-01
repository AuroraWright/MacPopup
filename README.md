# MacPopup

A native macOS overlay that shows text received over WebSockets (like
[texthooker-ui](https://github.com/Renji-XD/texthooker-ui)) in a floating box above every window,
including fullscreen apps, and lets you hover words to get a Yomitan-style dictionary popup with
Anki card creation. Lookups come from your installed Yomitan through the
[Yomitan API](https://github.com/yomidevs/yomitan-api).

In OCR mode, MacPopup instead reads another app's window (a game, say) with Apple's Live
Text or [meikiocr](https://github.com/rtr46/meikiocr) and lets you hover the window's own text, with no
text box at all.

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

The app is signed with the "Apple Development: Your Name (TEAMID)" certificate, so macOS keeps
its permissions (Screen Recording, Microphone, Accessibility) from one build to the next. Set
`MACPOPUP_SIGN_IDENTITY` to another identity, or to `-` to sign ad-hoc (without a certificate, the
permissions are asked for again after each build); without that identity in the keychain, the build
signs ad-hoc with a warning.

The app has no Dock icon. Use the menu bar item (speech bubble) for Settings, OCR mode,
hiding the overlay, moving it to another display, reloading, and quitting.

## Usage

- Text arrives from each WebSocket URL in Settings → WebSockets (default `ws://localhost:6677`).
  Plain text and texthooker JSON (`{"sentence": "..."}`) messages are both accepted.
- Drag the box by its header and resize it from the bottom right corner. Its position is saved.
- Hover a word to look it up. Settings → Scanning sets the modifier key (none by default), and
  whether lookups start at the character under the cursor or at the start of its word (Yomitan's
  scan resolution; as in Yomitan, the character is always used when the language is Japanese,
  Chinese, Cantonese or Korean).
  As in Yomitan, "Scan without mouse move" lets the scan key look up the word under a resting
  pointer.
- Inside a popup, hold Shift (configurable) and hover to open a nested popup. Settings → Scanning
  limits how many nested popups can open, and can make a click on a word in the definitions look it up
  in the same popup, as Yomitan's "Search terms when clicking text from the results list" does.
  Headwords are only scanned with "Allow scanning popup source terms", as in Yomitan.
- In a popup, as in Yomitan, the mouse wheel with Option moves between entries and with Shift goes
  back and forward in the popup's history, and so do the mouse's back and forward buttons (unless
  "Prevent mouse back and forward buttons in popups" is on).
- Yomitan's popup keyboard shortcuts (Settings → Popup Shortcuts) work while a popup shows, even with
  another app such as a game in front: close the popup, move between entries and dictionaries,
  go back and forward in history, add or view notes, play audio, copy the selection, or toggle a
  setting. While a popup shows, those keys go to MacPopup instead of the app in front.
- For combinations or mouse buttons, choose **Other (scanning inputs)** as the scan modifier key.
  You can then record or type a list of inputs, like Yomitan's scan inputs, and any one of them
  triggers scanning. As
  in Yomitan, an entry combines the modifier keys `meta`, `ctrl`, `alt` and `shift` with mouse
  buttons numbered like Yomitan's: `mouse0` left, `mouse1` right, `mouse2` middle, `mouse3` back,
  `mouse4` forward, `mouse5`. Examples: `meta`, `mouse3`, `mouse1 mouse2`, `ctrl mouse0`. A name
  with a leading `-` must not be held, like Yomitan's "exclude": `shift -mouse0` scans with Shift,
  but not while the left button is held. Add `terms` or `kanji` to look up only terms or only kanji,
  like Yomitan's per-input "Search terms" and "Search kanji": `alt kanji`.
- Clicking anywhere outside the popups closes them.
- Settings → Scanning → **Language** is your Yomitan profile's language (Import copies it). Lookups
  use Yomitan's own setting; MacPopup uses this one for the audio sources, for marking text with the
  language (so fonts use, say, Chinese rather than Japanese character forms), and for word scan resolution.
- Audio comes from the sources in Settings → Yomitan Popup → **Audio sources** (Yomitan's source types:
  JapanesePod101, Jisho.org, text-to-speech, a custom URL or a local audio server's JSON list, and so
  on), tried in order; Import → Yomitan Settings copies Yomitan's. As in Yomitan, "Enable default
  audio sources" adds the language's defaults after them when they aren't among them (JapanesePod101,
  LanguagePod101 and Jisho.org for Japanese; Lingua Libre, LanguagePod101 and Wiktionary otherwise), and "Enable audio playback for terms" turned off hides the play buttons. Without any sources,
  the Yomitan API plays the audio from Yomitan's own sources. Right-click a play button to choose among the audio every
  source has for the word (each voice of a local audio server, for example), as in Yomitan. The audio
  played from that menu, or marked with its card button, is used when you add the word to Anki.
- The header buttons pause new lines, clear lines, open Settings and hide the overlay.
- Settings → Window Mode → **Replacements** rewrites each new line with regular expressions, in order,
  like texthooker-ui's replacements (which Import brings over). Type a line under the list to see
  what the replacements make of it.
- Settings → Window Mode shows furigana from the Yomitan tokenizer, in hiragana, katakana, romaji or
  as the dictionary has it (Yomitan's "Reading mode", which also sets the furigana of
  `{sentence-furigana}` on cards; as in Yomitan, only hiragana and katakana change those), with or
  without space between words. Punctuation gets no furigana.
- Settings → Window Mode → **Enable background clipboard text monitoring** adds text copied in any app to the box, like
  Yomitan's background clipboard monitor (which opens its search page instead), up to the maximum
  length set. MacPopup's own copies and text password managers mark as concealed are skipped.

**Import** at the bottom of the Settings sidebar imports existing settings:

- **Yomitan Settings…** reads a Yomitan settings export (Yomitan Settings → Backup → Export
  Settings). If the export has several profiles, you pick one. It copies the language, the popup appearance and
  position, custom popup CSS, each dictionary's own styles and collapse mode, scan length, delay, resolution, modifier and other scanning options,
  nested popup and click search options, back/forward options, sentence parsing, the
  parser, furigana reading mode and term spacing, the clipboard monitor, audio playback, auto-play,
  volume, fallback sound and sources, the popup keyboard shortcuts, the Anki connection, tags, duplicate, card tag and flag,
  suspend, sync and screenshot options, and the Anki field templates.
- **texthooker-ui Settings…** reads a texthooker-ui settings export, so your theme, font size,
  replacements and so on carry over.

## OCR mode

Turn it on with **OCR Mode** in the menu bar, or Mode at Settings → General. The text box disappears, and words in the
captured window open popups when hovered, the same way as in the box. Without a captured window, the
whole screen the overlay is on is read instead (MacPopup's own windows aside). MacPopup needs the
Screen Recording permission (System Settings → Privacy & Security), which macOS asks for the first time.

- **Select Captured Window…** (or Select… at Settings → General → **Captured window**, which doesn't
  turn OCR mode on) covers the screen: click the window to
  read, then optionally drag over the parts that show text and click **Done** (or press Return).
  The first area is the dialogue (the game's text box): only it is matched with WebSocket lines and
  waits until it stops changing. Other areas (e.g. menus or choices) are taken to appear at once:
  they're read as soon as they change, which is checked like the window without a WebSocket (below),
  WebSocket or not. Without areas, the whole window is read as the dialogue. **Undo** (Delete) removes the
  last area or goes back to choosing the window, **Other Window** goes back to choosing it with no areas,
  and **Cancel** (Esc) keeps the previous choice. When the captured window is on screen, the picker
  starts from it and its areas, so they can be added to or removed.
  The window is found again by its app and title the next time MacPopup starts. **Clear** in
  Settings goes back to the whole screen. The captured window is also what Anki screenshots show.
- Text is recognized, horizontal or vertical, with Live Text or meikiocr (**Text recognition** in
  Settings → OCR Mode):
  - Live Text (the default) reads the language set in Settings → OCR Mode (Japanese by default; the
    menu lists every language Live Text supports on your version of macOS).
  - meikiocr's models, by rtr46, are trained on Japanese game text and read only Japanese. They run
    on this Mac with Core ML (converted by `scripts/convert-meikiocr.py`; see `vendor/meikiocr`).
    It's faster than Live Text and its character boxes fit the text more closely.

  The window is read right away and again until the text stops changing (for the settle time),
  instead of first waiting for the picture to be still, so a line usually shows in a fraction of a
  second, also over an animated background. A WebSocket line is shown as soon as a reading matches it.

  Only the chosen areas are captured, and a window drawn at 1x
  (e.g. a VM or a game that isn't Retina aware) is read at 1x, which is faster ("Read at" in
  Settings overrides this).
- Without a WebSocket, MacPopup watches the window (or the chosen areas) and reads it again when
  more than the change threshold of it changes. Small changes like a blinking cursor stay under the
  threshold, and so do spots that changed while the text stayed the same (e.g. a blinking "next"
  icon). Choosing areas helps with animated backgrounds. To save work,
  with "Watch after mouse use" (on by default) this only happens for a while (2 seconds) after the
  mouse moves or clicks (e.g. a click that advances the text), and the window is checked right away
  when it starts being used. Words are looked up when the cursor moves (or a scan key is
  pressed), not when new text appears under a resting cursor.
- The window is only read while it's on screen in the current space; it's read again when it comes
  back, and lines that arrive meanwhile are read then. Coming back, that reading is matched against the
  last WebSocket line like a new one, so it's read again if the window is still being redrawn.
- With a WebSocket connected, each new line is the cue to read the window instead, and the window
  is only watched for changes for a moment after each reading. Hooks usually send the line as the
  game starts drawing it, so MacPopup waits until the window stops changing before reading, and
  hides the previous text meanwhile. Recognized text that matches the line is
  corrected with it (the WebSocket text wins), and if it doesn't match yet, the window is read
  again. Only letters and digits decide whether it matches, since punctuation is often misread, and
  punctuation that looks alike is lined up (e.g. "……" read as "・・・・・"). The first reading
  after switching to OCR mode is matched against the last line received in window mode the same
  way. Turn this off with **Use WebSocket lines**.
- Words are only looked up while no other window covers the chosen one at the cursor.
- **Outline recognized text** in Settings is for debugging: it shows what was recognized, red for
  plain OCR text, green for lines corrected with the WebSocket line.

Live Text is read through a private VisionKit interface (the same one owocr uses), so a future
macOS version could change it.

## Yomitan popup

The popup uses Yomitan's own display code, templates and CSS, so it looks and behaves like the
extension's popup: dictionary entries, tags, frequencies, pitch accents, inflection info, kanji
entries, audio and history navigation.

Popup options that live in Yomitan's settings, such as theme, scale, size, position, custom CSS,
the styles that come with dictionaries and each dictionary's collapse mode, can't be read through the Yomitan API. MacPopup has its own copies of them in Settings → Yomitan Popup.
Use **Import Yomitan** to copy them over, or set them by hand.

## Anki

Card formats (deck, note type, field templates) and field values come from the selected Yomitan
profile through the API, so they match what the extension would create. MacPopup fills in the
markers the API can't know about from the overlay itself:

- `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}`,
  `{sentence-furigana-plain}`: from the line you looked up
- `{document-title}`: the name of the frontmost app
- `{screenshot}`: the captured window (Settings → General), by itself (no other windows or overlay),
  also outside OCR mode; without one, or while it isn't on screen, the display the overlay is
  on, without the overlay. This needs Screen Recording permission (System Settings → Privacy & Security).
- `{clipboard-text}`, `{clipboard-image}`, `{popup-selection-text}`

Templates can also read text selected in the popup (`getMedia "popupSelectionText"`), for example
to pick a dictionary by selecting its name. The API can't see the selection, so for this turn on
Settings → Anki → **Render the field templates below instead of using the Yomitan API**. MacPopup
then renders the fields itself with Yomitan's renderer and the field templates shown in Settings,
which **Import Yomitan** copies from your profile. Edit them there, or import again after changing
them in Yomitan.

Duplicate checks, "add duplicate", overwrite and "view note" work as they do in Yomitan, based on
the duplicate settings in Settings → Anki. So do Yomitan's other Anki options there: suspending new
cards, syncing after adding a card, showing the tags and flags of existing cards (and their state on
the "view note" button), the quick duplicate check before notes are made, and the download timeout
for audio added to cards.

### Sentence audio

Settings → **Anki Sentence Audio** records a game's voice line for the cards you just added, with a
shortcut that works in any app:

1. MacPopup switches to the game (the captured window from Settings → General, also outside OCR
   mode, or an app you name) and presses the keys you recorded to open its backlog, where the line
   can be replayed.
2. It records the audio input you chose, e.g. a virtual device (Loopback, BlackHole) that the game's
   sound goes to. With **Detect when the voice starts and ends** (on by default), macOS's sound
   classifier listens for speech, so music and sound effects don't count: the recording stops once
   the voice has been gone for 3 seconds (**The voice has ended after**), and only the voice is
   kept, with **Detected voice padding** before and after it. If none is heard in time,
   nothing is saved. Otherwise, recording starts after **Wait before recording**, and the shortcut
   stops it.
3. It presses the keys that close the backlog.
4. The recording goes into the sentence audio field (chosen from your note types' fields) of the
   newest card added today, and of the other cards added today with the same sentence (ignoring
   formatting) whose field is empty. Their sentence is the field their Yomitan card format fills
   with `{sentence}` (or the sentence with furigana, or a cloze). They're
   shown in Anki's card browser, and the recording is played (both optional).

Recording needs Microphone permission, and pressing keys needs Accessibility permission (System
Settings → Privacy & Security), which macOS asks for the first time.

## Limitations

- The overlay never takes keyboard focus. Keyboard shortcuts work through global hotkeys while a
  popup shows (see Usage); Yomitan's profile switching shortcuts aren't supported.
- Prefix matching isn't available: the Yomitan API only finds exact matches.
- Because WebKit only sends hover events to the focused window, CSS `:hover` effects (such as
  button highlights) only show while MacPopup is the active app. Lookups and nested lookups don't
  depend on this.
- Outside OCR mode, scanning works on the overlay's own text, not on other apps.

## License

GPL-3.0, because it includes code from [Yomitan](https://github.com/yomidevs/yomitan) (see
`vendor/yomitan/README.md` for the commit). See `LICENSE`.

meikiocr's models (in `vendor/meikiocr`, converted to Core ML) are licensed under the LGPL-3.0, and
`Sources/MacPopup/MeikiOCR.swift` follows meikiocr's code, licensed under the Apache License 2.0; see
`vendor/meikiocr/README.md`.
