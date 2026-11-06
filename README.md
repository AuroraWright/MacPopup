# MacPopup

MacPopup is a native macOS overlay for looking up words with
[Yomitan](https://github.com/yomidevs/yomitan) and mining flashcards to Anki—even over fullscreen
games and apps. It works in two modes:

- **Window Mode**: Receives text over WebSockets (from tools like Textractor, Agent, or
  LunaTranslator) and displays it in a customizable floating text box (similar to
  [texthooker-ui](https://github.com/Renji-XD/texthooker-ui)).
- **OCR Mode**: Hides the text box and reads text directly from any app or game window on screen
  using Apple Live Text, [meikiocr](https://github.com/rtr46/meikiocr),
  [PP-OCRv6 Manga](https://huggingface.co/Kellenok/PP-OCRv6_manga), Chrome's Screen AI, or Windows' OneOCR
  (with optional Google Lens or Bing cloud passes). Simply hover over the game's own
  text to open dictionary popups.

All dictionary lookups and Anki card templates are powered by your existing browser installation of
Yomitan through the [Yomitan API](https://github.com/yomidevs/yomitan-api).

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Xcode** (or Xcode Command Line Tools with Swift 5.9+) and **Node.js 18+** to build
- **Yomitan** with the [Yomitan API](https://github.com/yomidevs/yomitan-api) native messaging host
  installed (default: `http://127.0.0.1:19633`). **Install** next to the Yomitan API URL (*Settings → Scanning*)
  installs MacPopup's own version of it, which doesn't need Python, for Chrome, Chromium, Brave or Firefox. Then restart
  the browser and turn on *Enable Yomitan API* in Yomitan's settings (*General*, with advanced options shown).
- **Anki** with the **AnkiConnect** add-on for flashcard creation (default: `http://127.0.0.1:8765`)

---

## Build and Run

```sh
cd web && npm install && cd ..
scripts/build.sh            # Builds release app at build/MacPopup.app
open build/MacPopup.app
```

- Run `scripts/build.sh debug` for a debug build.
- The first build automatically downloads Yomitan's kanji stroke-order font into `build/cache`.
- **Code Signing & Permissions**: To prevent macOS from asking for Screen Recording, Microphone, and
  Accessibility permissions again after every rebuild, `scripts/build.sh` signs the app with a fixed
  certificate, "Apple Development: Your Name (TEAMID)". Set `MACPOPUP_SIGN_IDENTITY` to your own
  certificate's name, or to `-` for ad-hoc signing (macOS then asks for the permissions again after
  each build). Without the certificate in your keychain, the build signs ad-hoc with a warning.

MacPopup runs in the background without a Dock icon. Click the **speech bubble icon in the menu
bar** to open Settings, switch between Window Mode and OCR Mode, select a target window, hide the
overlay, move between displays, or quit.

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

## OCR Mode

Switch to **OCR Mode** from the menu bar icon or **Settings → General**. The floating text box
hides, allowing you to hover directly over text inside your game or app window. (Requires **Screen
Recording** permission in *System Settings → Privacy & Security*.)

### Selecting a Window and Capture Areas

Choose **Select Captured Window…** from the menu bar (or click **Select…** next to **Captured
window** in *Settings → General*):

1. **Click the window** you want MacPopup to read (or click **Clear** in Settings to read the entire
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

Choose your engine in **Settings → OCR Mode → Text recognition engine**. Whatever the engine, lines
without any characters of the language set in *Settings → General* are skipped (e.g. an English menu
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
  WebSocket line keep its text. The requests are made like
  [owocr](https://github.com/AuroraWright/owocr)'s, as Chrome makes them, through
  [curl-impersonate](https://github.com/lexiforest/curl-impersonate), which `scripts/build.sh`
  downloads into the app.

### Hybrid WebSocket + OCR Matching

If you have both a text hook (WebSocket) and OCR Mode running—with **Match and fix OCR with
WebSocket text** enabled—you get the best of both worlds:

- Hover words directly on the game screen using OCR's character positions, while MacPopup
  automatically replaces any misread OCR characters with the exact text from the WebSocket line.
- Works with partial lines (such as multi-page sentences) and games that stack multiple lines on
  screen at once (**Previous WebSocket lines to match**).
- Furigana is automatically stripped in Japanese (**Ignore furigana**) so small readings above kanji
  don't interfere with recognition.

### Performance & Troubleshooting

- **CPU Saving**: By default, **Only check for changes after mouse activity** checks the window for
  new text for 2 seconds after you click or move the mouse (such as clicking to advance dialogue),
  rather than polling constantly while you read.
- **Visual Debugging**: Turn on **Highlight recognized text boxes (debug)** in *Settings → OCR Mode*
  to outline detected text on screen (**Red** = local OCR, **Orange** = cloud OCR, **Green** =
  WebSocket-corrected) and write detailed logs to `~/Library/Application
  Support/MacPopup/ocr-debug.jsonl`.

For an in-depth technical explanation of the OCR pipeline and timing settings, see
[docs/ocr-mode.md](docs/ocr-mode.md).

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

**Settings → Anki Sentence Audio** lets you press a single global shortcut after mining a card to
automatically record the character's voice line from your game's dialogue backlog:

1. **Focus & Replay**: MacPopup brings your game window to the front and presses your recorded
   **Keys to open backlog and replay voice**.
2. **Smart Voice Recording**: Records from your selected **Audio input device** (such as BlackHole
   or Loopback). With **Automatically detect start and end of speech** enabled, macOS's sound
   classifier ignores background music and sound effects, starts recording when speech begins, and
   stops automatically after the voice ends. If no voice is heard in time, nothing is saved. With
   detection off, press the shortcut again to stop recording.
3. **Return to Game**: Presses your **Keys to close backlog**.
4. **Attach to Card**: Saves the audio clip into your chosen **Target Anki field** on the newest
   card created today, and on any other cards added today with the same sentence, if that field is
   empty. The recording is then played back (optional).

Requires **Microphone** and **Accessibility** permissions (*Settings → Permissions*).

---

## iPhone App

The `ios/` folder has an iPhone app (iOS 18 or later) that reads the text in a picture with the same engines and
opens it in **Safari**, as the picture with invisible text over it, for a Safari dictionary extension such as Yomitan
to look up. Readings keep opening in Safari after the app is closed.

Build it by opening `ios/MacPopup.xcodeproj` in Xcode, choosing your own team under *Signing & Capabilities* for each
target (MacPopup, Controls, Share and Broadcast), and running it on your iPhone. Node.js is needed, as for the Mac app. The app
has Live Text, meikiocr and PP-OCRv6 Manga, and Screen AI and OneOCR once their models are loaded: put the same .zip
files the Mac app loads (see OCR Engines above) in Files, then load them in the app's Settings.

Pictures can come from Photos, Files, the clipboard, or the latest screenshots, which the app lists once it's allowed
full access to Photos. They can also be shared to **MacPopup** from other apps' share sheets, including an image
long-pressed in Safari. With *Crop before reading* on (Settings), pictures chosen in the app open in a crop view first.
Swipe a reading left to delete it. To read what's on the screen without opening the app:

- **Back Tap** (*Settings → Accessibility → Touch → Back Tap*): make a Shortcut with **Take Screenshot** followed by
  MacPopup's **Read Image**, and choose it for Double or Triple Tap. The screenshot is read with the app in the
  background, and the reading opens in Safari.
- **Action button** (iPhone 15 Pro and later, *Settings → Action Button*): choose the same Shortcut, or choose
  *Controls* and MacPopup's **Read Latest Screenshot** to read the screenshot taken last.
- **Control Center**: add MacPopup's **Read Latest Screenshot** control, take a screenshot, then tap the control.
- **Siri**: "Read my latest screenshot with MacPopup".
- **Visual Intelligence** (iOS 26 with Apple Intelligence): from the camera (Action button, Control Center or Camera
  Control) or a screenshot's Visual Intelligence button, pick MacPopup's *Read with MacPopup* result. The picture is
  read when you open it, and the reading opens in Safari.

**Continuous Reading** reads the screen as it changes, e.g. a game's dialogue, while you play. Tap *Start Reading the
Screen* (a screen broadcast, also in Control Center), switch to the game, then come back and *Add Area…* around the
dialogue on a screen it read, so that only that part is watched and read. Each new line goes to the live page in
Safari (*Open the Live Page*), newest first, with the earlier ones below; switch to it to look words up, and back to the
game. Reading pauses while the live page is in front. *Show the Latest Text* adds a Picture in Picture window over the
game with the new lines. Stopping the broadcast stops reading.

- The app keeps running in the background with a silent audio session, and reads on the CPU, since iOS doesn't let
  background apps use the GPU: about half a second per area on an iPhone 15 Pro Max. Screen AI needs the GPU, so
  continuous reading uses meikiocr instead of it.
- It uses more battery. The *Reading* settings set how often the screen is checked and how much an area must change.
- Protected video (DRM) comes out black in a broadcast.

---

## Known Limitations

- **No Prefix Matching**: The Yomitan API only supports exact term lookups, so prefix search is
  unavailable.
- **CSS `:hover` Highlights**: Because macOS WebKit only sends CSS hover events to the active
  application, button hover highlights inside popups only appear when MacPopup itself is focused.
  Word lookups and nested popups work normally regardless of focus.
- **Profile Switching Shortcuts**: Yomitan's keyboard shortcuts for switching profiles inside a
  popup are not supported.
- **Keyboard Focus**: The overlay never takes keyboard focus; popup shortcuts work through global
  hotkeys while a popup is open.
- **Window Mode Lookups**: Outside OCR Mode, lookups work on the text box's own text, not on other
  apps.
- **Live Text**: Live Text is used through a private VisionKit interface (the same one owocr uses),
  so a future macOS version could change it.

---

## License

Licensed under the **GPL-3.0** as it includes code from
[Yomitan](https://github.com/yomidevs/yomitan) (see `vendor/yomitan/README.md` and `LICENSE`).

The `meikiocr` Core ML models (`vendor/meikiocr`) are licensed under the **LGPL-3.0**, and
`Sources/OCREngines/MeikiOCR.swift` is adapted from `meikiocr` under the **Apache License 2.0** (see
`vendor/meikiocr/README.md`).

The PP-OCRv6 Manga Core ML models (`vendor/ppocr-manga`) are licensed under the **Apache License 2.0** (see
`vendor/ppocr-manga/README.md`).
