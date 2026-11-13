# MacPopup

<img src="Resources/AppIcon.png" alt="MacPopup’s icon" width="128" align="right">

The creatively-named MacPopup is a native macOS overlay for looking up words with
[Yomitan](https://github.com/yomidevs/yomitan) and mining flashcards to Anki—even over fullscreen
games and apps. It works in two modes:

- **Window Mode**: Inspired by [JL](https://github.com/rampaa/JL). Receives text over WebSockets
  or from the clipboard (from tools like Textractor, Agent, or LunaTranslator) and displays it in a customizable floating
  text box (similar to [texthooker-ui](https://github.com/Renji-XD/texthooker-ui)).
- **OCR Mode**: Inspired by [meikipop](https://github.com/rtr46/meikipop) and
  [GameSentenceMiner](https://github.com/bpwhelan/GameSentenceMiner). Hides the text box and
  reads text directly from any app or game window on screen using Apple Live Text, [meikiocr](https://github.com/rtr46/meikiocr),
  [PP-OCRv6 Manga](https://huggingface.co/Kellenok/PP-OCRv6_manga), Chrome's Screen AI, or Windows' OneOCR
  (with optional Google Lens or Bing cloud passes). Simply hover over the game's own
  text to open dictionary popups.

All dictionary lookups and Anki card templates are powered by your existing browser installation of
Yomitan through the [Yomitan API](https://github.com/yomidevs/yomitan-api), which you can install
directly from MacPopup.

---

## Requirements

- **macOS 15 (Sequoia)** or later on an Apple Silicon Mac
- **Yomitan** with the [Yomitan API](https://github.com/yomidevs/yomitan-api) native messaging host
  installed (default: `http://127.0.0.1:19633`). **Install** next to the Yomitan API URL (*Settings → Scanning*)
  installs MacPopup's own version of it, which doesn't need Python, for Chrome, Chromium, Brave or Firefox. Then restart
  the browser and turn on *Enable Yomitan API* in Yomitan's settings (*General*, with advanced options shown).
- **Anki** with the **AnkiConnect** add-on for flashcard creation

---

## Running

MacPopup runs in the background without a Dock icon. Click the **speech bubble icon in the menu bar** to open Settings,
switch between Window Mode and OCR Mode, select a target window, hide the overlay, move between
displays, or quit.

---

## Quick Start: Importing Your Settings

You don't need to configure MacPopup from scratch. At the bottom of the Settings sidebar, click
**Import**:

- **Yomitan Settings…**: Select a Yomitan settings backup file (*Yomitan Settings → Backup → Export
  Settings*). If your backup has multiple profiles, you'll be prompted to choose one. This imports
  your language, popup theme and size, custom CSS, dictionary styles and collapse rules, scanning
  preferences, audio sources, popup keyboard shortcuts, Anki settings, and card templates.
- **texthooker-ui Settings…**: Select a texthooker-ui export to bring over your text box theme, font
  size, line rules, and regex text replacements.

---

## Window Mode

In Window Mode, MacPopup listens to every WebSocket URL listed in **Settings → WebSockets**
(default: `ws://localhost:6677`), accepting both plain text and texthooker JSON (`{"sentence":
"..."}`).

- **Move & Resize**: Drag the floating text box by its top header and resize it from the
  bottom-right corner. Header buttons let you pause incoming lines, clear the box, open Settings, or
  hide the overlay.
- **Clipboard Monitoring**: Turn on **Read copied text from clipboard** (*Settings → Window Mode*)
  to automatically add text copied in any other app to the text box (passwords from password
  managers are ignored).
- **Furigana & Formatting**: Display furigana above words (in Hiragana, Katakana, Romaji, or
  dictionary reading), add spaces between parsed words, display text vertically, or filter out
  duplicate and non-CJK lines.
- **Text Replacements**: Apply regular expression find-and-replace rules (*Settings → General*) in
  order to clean up incoming lines before they are displayed. Use the test field below the list to
  preview how your rules transform a sample line. In OCR Mode, they apply to WebSocket lines before
  they're matched with the recognized text.

---

## Looking Up Words & Using Popups

MacPopup is designed to be a "system-wide Yomitan": its popups look and behave like Yomitan's in
the browser, with your own dictionaries, settings and Anki templates, over any app or game.

- **Hover to Look Up**: Move your cursor over a word to open a Yomitan popup. By default, no
  modifier key is needed. You can require a key (`Option`, `Control`, `Shift`, `Command`) or
  configure **Other** in **Settings → Scanning** to combine keys and mouse buttons (e.g.,
  `shift -mouse0` or `alt kanji`).
- **Nested Popups**: Hold `Shift` (configurable) while hovering inside a popup to open a child
  popup. You can also enable **Search terms when clicking text from the results list** to search
  within the same popup, or **Allow scanning popup source terms** to look up headwords too.
- **Mouse Navigation**:
  - `Option + Scroll wheel`: Move between dictionary entries.
  - `Shift + Scroll wheel` or **Mouse Back/Forward buttons**: Navigate backward and forward through
    lookup history.
  - Click anywhere outside the popup to close it.
- **Popup Keyboard Shortcuts**: Shortcuts configured in **Settings → Popup Shortcuts** work whenever
  a popup is open—even when a game or another app is focused. While a popup is visible, those keys
  are sent to MacPopup to close the popup, jump between entries or dictionaries, play audio, or add
  Anki cards.
- **Pronunciation Audio**: Configure audio sources in **Settings → Yomitan Popup → Audio sources**.
  Click the speaker icon on an entry to play the first available match, or **right-click the speaker
  icon** to choose from all available recordings across your sources. The recording you play or mark
  from that menu is also used when you add the word to Anki.

---

## Game Controllers

You can look up words and control popups with a game controller (DualShock 4, Switch Pro
Controller, Xbox controllers and others), without putting it down.

- **Set Up Your Controller**: In **Settings → Controllers**, connect your controller, click
  **Set Up…**, and press its buttons as shown. MacPopup learns where each button is, so it can take
  over the controller while you look up words—your game won't react to it meanwhile, and doesn't
  see it disconnect. MacPopup only uses controllers that are set up.
- **Look Up Words**: In **Settings → Scanning**, record a **Controller scan key**—a button
  combination your game doesn't use, such as `L3 + R3`. Press it to start looking up words in the
  text box or the OCR Mode text, then move with the D-pad or left stick. When you stop moving, the
  popup for that word opens (after the **Controller popup delay**, 1 second by default). Press the
  combination again to close the popup and give the controller back to your game.
  - With **Scan resolution** set to **Character**, you move one character at a time and choose
    exactly where a word starts. Set to **Word**, you jump from word to word.
  - In OCR Mode, you start in the dialogue box: on the most recent WebSocket line if it's on screen,
    or else on the bottom or top sentence (**Controller OCR Mode starting position**).
- **Control Popups**: Any shortcut in **Settings → Popup Shortcuts** can also have a controller
  button combination (**Record Buttons**). While a popup is open, your game won't react to a
  controller that's set up; when no popup is open, the buttons go to your game as usual.
- **Record Sentence Audio**: **Settings → Game Sentence Audio** can also have a controller button
  combination, which works like its keyboard shortcut at any time. Like the scan key, pick buttons
  your game doesn't use.

---

## OCR Mode

Switch to **OCR Mode** from the menu bar icon or **Settings → General**. The floating text box
hides, allowing you to hover directly over text inside your game or app window. (Requires **Screen
Recording** permission in *System Settings → Privacy & Security*.)

### Selecting a Window and Capture Areas

Choose **Select Captured Window…** from the menu bar (or click **Select…** next to **Captured
window** in *Settings → General*):

1. **Click the window** you want MacPopup to read (or click **Whole Screen** to read the entire
   screen).
2. **Optional — Drag over text areas**: Draw rectangles over the specific regions where text
   appears, then click **Done** (`Return`).
   - **First area (Dialogue box)**: Waits for text animations to settle before finalizing, and
     matches against incoming WebSocket lines.
   - **Additional areas (Menus, choices, UI)**: Read immediately as soon as they change.
   - Use **Undo** (`Delete`) to remove the last area, **Other Window** to pick a different window,
     or **Cancel** (`Esc`) to keep your previous selection. Switching to another app or Space also
     goes back to picking a window.

When you select again, the window you're reading is brought to the front first (from another Space
too), with its areas.

MacPopup remembers the window by its app name and title across launches. It's only read while it's
on screen in the current Space. The selected window is also used for clean `{screenshot}` captures
on Anki cards (even when you are using Window Mode).

### OCR Engines

Choose your engine in **Settings → OCR Mode → Text recognition engine**. Lines without any characters
of the language set in *Settings → General* are skipped (e.g. an English menu
in a Japanese game).

- **Live Text** *(Default)*: Built into macOS. Recognizes the language selected in *Settings
  → General* plus English.
- **meikiocr**: Built-in Core ML models (by rtr46) trained specifically on Japanese video games.
  Faster than Live Text with tighter character bounding boxes (Japanese only).
- **PP-OCRv6 Manga**: Built-in Core ML models (by Kellenok, fine-tuned from PaddleOCR's PP-OCRv6)
  trained on manga and anime: vertical text in speech bubbles, sound effects (Japanese and Chinese).
- **Screen AI**: Google Chrome's local OCR engine running on Core ML. Supports most scripts
  and detects layout and reading order automatically.
  - *Setup*: Make sure Chrome has downloaded its Screen AI component (`~/Library/Application
    Support/Google/Chrome/screen_ai`), run `scripts/convert-screenai.py` to generate a `.zip` file,
    and load it under **Screen AI models → Load…**.
- **OneOCR**: The OCR engine from the Windows 11 Snipping Tool. Supports most scripts
  automatically.
  - *Setup*: Run `scripts/convert-oneocr.py` on your decrypted OneOCR model files (`config.json` and
    `Model_Edge`) to create a `.zip` file, and load it under **OneOCR models → Load…**.
- **Cloud recognition (second pass)**: Optionally enable **Google Lens** or **Bing**. Local OCR
  reads the text first for fast responsiveness; once a dialogue line settles, an image of the
  dialogue area is sent to Google Lens or Bing for a higher-accuracy reading. Lines matched with a
  WebSocket line keep its text.

### Hybrid WebSocket + OCR Matching

If you have both a text hook (WebSocket) and OCR Mode running—with **Match and fix OCR with
WebSocket text** enabled—you get the best of both worlds:

- Hover words directly on the game screen using OCR's character positions, while MacPopup
  automatically replaces any misread OCR characters with the exact text from the WebSocket line.
- Works with partial lines (such as multi-page sentences) and games that stack multiple lines on
  screen at once (**Previous WebSocket lines to match**).
- Furigana is automatically stripped in Japanese (**Ignore furigana**) so small readings above kanji
  don't interfere with recognition.

---

## Anki Integration

MacPopup creates flashcards through your active Yomitan profile and fills in context markers
automatically:

- `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}`,
  `{sentence-furigana-plain}`: Extracted from the line you looked up.
- `{screenshot}`: A clean capture of your selected **Captured window** (without overlays or covering
  windows), or the current screen if no window is chosen (or it isn't on screen). Taken at 1x, or at
  the display's Retina scale with **Screenshot resolution** set to Full Retina resolution (*Settings
  → Anki*).
- `{document-title}`: The name of the active foreground app.
- `{clipboard-text}`, `{clipboard-image}`, `{popup-selection-text}`: Current clipboard contents or
  text highlighted inside the popup.

> **Using Selected Popup Text in Handlebars Templates**: The Yomitan API cannot see text you
> highlight inside a MacPopup popup. If your custom Anki templates rely on popup text selection,
> enable **Use local Handlebars templates** in *Settings → Anki* and import your Yomitan settings so
> MacPopup renders the templates directly. Templates read the selection with `getMedia
> "popupSelectionText"`, e.g. to pick a dictionary by selecting its name.

### Automatic Sentence Audio Recording

**Settings → Game Sentence Audio** lets you press a single global shortcut after mining a card to
automatically record the character's voice line from your game's dialogue backlog:

1. MacPopup brings your game window to the front, presses your recorded **Keys to open backlog**,
   and waits for you to replay the voice line.
2. Records the game's own audio (or that of every app but MacPopup when no window is captured).
   With **Automatically detect start and end of speech** enabled, macOS's sound
   classifier ignores background music and sound effects, starts recording when speech begins, and
   stops automatically after the voice ends. If no voice is heard in time, nothing is saved. With
   detection off, press the shortcut again to stop recording.
3. Presses your **Keys to close backlog**.
4. Saves the audio clip into the **Sentence audio field** (*Settings → Anki*) on the newest
   card created today, and on any other cards added today with the same sentence, if that field is
   empty. The recording is then played back (optional).

You can also start a recording with a controller button combination (see [Game Controllers](#game-controllers)).

Requires the **Accessibility** permission (*Settings → Permissions*), and permission to record other apps'
audio, which the first recording asks for (*System Settings → Privacy & Security → Screen & System Audio Recording*).

### Videos in IINA

The [IINA](https://iina.io) plugin in `iina-plugin/` sends the subtitles you're watching to MacPopup, and gives cards
made from them the line's own frame and audio:

1. Click **Install** in *Settings → IINA Integration*, which opens the plugin in IINA (or run
   `iina-plugin link iina-plugin` from IINA's `Contents/MacOS` for development), turn the plugin on in IINA's
   *Settings → Plugins*, and restart IINA. The plugin asks for permission to access files, which it needs for live streams and
   cookies (see step 3).
2. Add `ws://localhost:6680` in MacPopup's *Settings → WebSockets* (the port can be changed in the
   plugin's settings). Each subtitle line arrives like a text hooker's, so you can read them in the text box, or hover
   the subtitles on the video in OCR Mode with **Match and fix OCR with WebSocket text** on.
3. For a sentence from one of these lines, `{screenshot}` is the frame in the middle of the line, without
   subtitles, at the video's size, and the **Sentence audio field** (*Settings → Anki*) gets the line's audio, with the
   padding set in *Settings → IINA Integration* (where it can be turned off). This works for network streams too
   (including web videos IINA plays through yt-dlp): MacPopup will access them over the network using IINA's configured
   headers, cookies and proxy, and for live streams it takes the line from IINA's cache, which holds roughly the last
   minute played.

---

## iPhone App (Experiment)

`ios/` has an experimental iPhone app that reads pictures and the screen with the same OCR engines and opens the text
in Safari for a dictionary extension such as Yomitan. It's separate from MacPopup: see [ios/README.md](ios/README.md).

---

## Limitations compared to Yomitan

- **No Prefix Matching**: The Yomitan API only supports exact term lookups, so prefix search is
  unavailable.
- **Profile Switching Shortcuts**: Yomitan's keyboard shortcuts for switching profiles inside a
  popup are not supported.

---

## Building

Building needs Swift 5.9+ (the Xcode Command Line Tools) and Node.js 18+.

```sh
cd web && npm install && cd ..
scripts/build.sh            # Builds release app at build/MacPopup.app
```

- Run `scripts/build.sh debug` for a debug build.
- The first build automatically downloads Yomitan's kanji stroke-order font into `build/cache`.
- **Code Signing & Permissions**: To prevent macOS from asking for Screen Recording and
  Accessibility permissions again after every rebuild, sign the app with your own certificate: write
  its name (as listed by `security find-identity -v -p codesigning`, e.g. "Apple Development: Your
  Name (TEAMID)") in a `.signing-identity` file at the top of the repository (it's kept out of git),
  or set `MACPOPUP_SIGN_IDENTITY`. Otherwise the build signs ad-hoc, and macOS asks for the
  permissions again after each build.
- **Notarization**: `scripts/notarize.sh` builds a notarized copy to hand out, in `build/notarized`
  (the app and a zip of it). It needs a "Developer ID Application" certificate (or set
  `MACPOPUP_NOTARY_IDENTITY`) and a notarytool keychain profile, made with `xcrun notarytool
  store-credentials`, whose name goes in a `.notary-profile` file (kept out of git) or
  `MACPOPUP_NOTARY_PROFILE`.

---

## License

Licensed under the **GPL-3.0**.

Large parts of the codebase are derived from [Yomitan](https://github.com/yomidevs/yomitan) (with extra changes from the
[OwOtan](https://github.com/AuroraWright/owotan) fork; see `vendor/yomitan/README.md` and `LICENSE`).

The text box's line processing, settings and replacements are adapted from
[texthooker-ui](https://github.com/Renji-XD/texthooker-ui) under the **MIT License** (see `vendor/texthooker-ui/README.md`
and `vendor/texthooker-ui/LICENSE`).

The `meikiocr` Core ML models (`vendor/meikiocr`) are licensed under the **LGPL-3.0**, and
`Sources/OCREngines/MeikiOCR.swift` is adapted from `meikiocr` under the **Apache License 2.0** (see
`vendor/meikiocr/README.md`).

The PP-OCRv6 Manga Core ML models (`vendor/ppocr-manga`) are licensed under the **Apache License 2.0** (see
`vendor/ppocr-manga/README.md`).
