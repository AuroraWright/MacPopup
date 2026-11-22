# MacPopup

<img src="Resources/AppIcon.png" alt="MacPopup’s icon" width="128" align="right">

The creatively named MacPopup is a native macOS overlay for looking up words with
[Yomitan](https://github.com/yomidevs/yomitan) and making Anki cards, even over full-screen games and apps. It has two
modes:

- **Floating Window**: Inspired by [JL](https://github.com/rampaa/JL). Shows text in a floating text box you can
  customize, like [texthooker-ui](https://github.com/Renji-XD/texthooker-ui). The text comes from WebSockets or the
  clipboard (from tools like Textractor, Agent or LunaTranslator), or is read from a game's window with OCR or from
  its voices.
- **OCR overlay**: Inspired by [meikipop](https://github.com/rtr46/meikipop) and
  [GameSentenceMiner](https://github.com/bpwhelan/GameSentenceMiner). Reads the text straight from any app or game
  window, so you can point at the game's own text to look words up. It uses Apple Live Text,
  [meikiocr](https://github.com/rtr46/meikiocr), [PP-OCRv6 Manga](https://huggingface.co/Kellenok/PP-OCRv6_manga),
  [mida](https://huggingface.co/rtr46/mida) + [VOCR6](https://github.com/bee-san/vita-vn-ocr), Chrome's Screen AI
  or Windows' OneOCR, optionally followed by Google Lens or Bing.

Lookups and Anki card templates come from the Yomitan you already use in your browser, through the
[Yomitan API](https://github.com/yomidevs/yomitan-api), which MacPopup can install for you.

---

## Requirements

- **macOS 15 (Sequoia)** or later on an Apple Silicon Mac
- **Yomitan** with the [Yomitan API](https://github.com/yomidevs/yomitan-api) (at `http://127.0.0.1:19633` by
  default). To set it up, click **Install** next to **Yomitan API URL** (*Settings → Scanning*): it installs
  MacPopup's own version, which doesn't need Python, for Chrome, Chromium, Brave or Firefox. Then restart the browser
  and turn on *Enable Yomitan API* in Yomitan's settings (*General*, with advanced options shown).
- **Anki** with the **AnkiConnect** add-on, to make cards

---

## Running

MacPopup runs in the background, without a Dock icon. Click its **speech bubble icon in the menu bar** to open
Settings, switch between the Floating Window and the OCR overlay, choose the window to read, hide the overlay, move it
to another display, or quit. To hide the overlay from any app, set the **Overlay hide key/buttons** in *Settings →
General*.

---

## Quick Start: Importing Your Settings

You don't have to set MacPopup up from scratch: click **Import** at the bottom of the Settings sidebar.

- **Yomitan Settings…**: Choose a Yomitan settings backup (*Yomitan Settings → Backup → Export Settings*), and a
  profile if it has several. This brings over your language, popup theme and size, custom CSS, dictionary styles and
  collapse rules, scanning settings, audio sources, popup shortcuts, Anki settings and card templates.
- **texthooker-ui Settings…**: Choose a texthooker-ui export to bring over your text box theme, font size, line
  settings and text replacements.
- **MacPopup Settings…**: Restore a file saved with **Export…**. This replaces all your current settings.

If your Yomitan shares its settings through its API (not in a Yomitan release yet), you don't need to import
anything: popups follow your Yomitan's look, dictionaries and collapse rules, and stay in sync when you change them
there. To use MacPopup's own look, turn off *Use Yomitan's display settings* in *Settings → Yomitan Popup*. With an
older Yomitan, MacPopup uses what you imported.

---

## Floating Window

The Floating Window shows the lines from every WebSocket in **Settings → WebSockets** (`ws://localhost:6677` by
default), as plain text or texthooker JSON (`{"sentence": "..."}`).

- **Move & Resize**: Drag the text box by its top edge, and resize it from its bottom-right corner. Hover it to show
  buttons above its top-right corner: turn clipboard reading, OCR or audio on and off, pause new lines, clear the box,
  open Settings, or hide the overlay.
- **Clipboard**: Turn on **Read copied text from clipboard** (*Settings → Floating Window*) to add text you copy in
  other apps to the box. Passwords copied from password managers are skipped.
- **Read text from OCR**: Turn on **Read text from OCR** (*Settings → Floating Window*, or the **OCR** button) to read
  the game's text with OCR and add it to the box, like a text hooker. It reads the dialogue area, or the whole window
  if you haven't drawn one (see [Selecting a Window and Capture Areas](#selecting-a-window-and-capture-areas)). When a
  page fills up over time, as in visual novels, each new sentence or paragraph becomes its own line. Lines that
  already came over WebSocket aren't added twice. A window may not be readable while it's hidden. Lines the OCR
  overlay reads are added too, so they're there when you switch back.
- **Read text from audio**: Turn on **Read text from audio** (*Settings → Floating Window*, or the **audio** button)
  to add what's said in the captured window's app (or in any app, if no window is captured) to the box, a sentence
  per line. Music and sound effects are skipped. MacPopup needs the **System Audio Recording** permission.
  - *Models*: Choose one in *Settings → Transcription*. None come with MacPopup: make a `.zip` file with the
    `scripts/convert-*.py` script named there, and click **Load**. **Live Caption** (the default, Chrome's speech
    recognition) covers 16 languages, **Kitsune** is fast and accurate for Japanese, **SenseVoice** covers Chinese,
    Cantonese, Japanese, Korean and English, **Parakeet** 25 European languages, **Whisper** 99 languages, and
    **anime-whisper** is the most accurate for game and anime voices but slower.
  - *Lines*: A new line starts when the speaker pauses for a second (change it with **Line ends after a pause of**).
    To end lines where sentences end instead, which is also more accurate, turn on **Detect sentence ends**, load the
    SaT model the same way, and set the pause to 200. To see the words as they're spoken, turn on **Show words as
    they're heard** (not available with Whisper and anime-whisper).
- **Font & Formatting**: Pick the box's font, size, color, underline, strikethrough, shadow and background in the
  macOS Fonts panel (*Settings → Floating Window → Font*). Show furigana above words (in hiragana, katakana, romaji or
  the dictionary reading), add spaces between words, show text vertically, or hide duplicate lines and lines that
  aren't in your language.
- **Text Replacements**: Clean up incoming lines with regular-expression find-and-replace rules
  (*Settings → General*), applied in order. The test field under the list shows what your rules do to a sample line.
  With the OCR overlay, they're applied to WebSocket lines before those are matched with the text on screen.

---

## Looking Up Words & Using Popups

MacPopup aims to be a "system-wide Yomitan": its popups look and work like Yomitan's in your browser, with your
dictionaries, settings and Anki templates, over any app or game.

- **Hover to Look Up**: Point at a word to open a popup. No key is needed by default. You can require one (`Option`,
  `Control`, `Shift` or `Command`), or choose **Other** in **Settings → Scanning** to combine keys and mouse buttons
  (e.g. `shift -mouse0` or `alt kanji`).
- **Nested Popups**: Hold `Shift` (or the key you set) while pointing at a word in a popup to open another popup.
  You can also turn on **Search terms when clicking text from the results list** to search within the same popup, or
  **Allow scanning popup source terms** to look up headwords too.
- **Mouse Navigation**:
  - `Option` + scroll: Move between entries.
  - `Shift` + scroll, or the mouse's **Back/Forward buttons**: Go back and forward through your lookups.
  - Click outside the popup to close it.
- **Popup Shortcuts**: The shortcuts in **Settings → Popup Shortcuts** work while a popup is open, even with a game
  or another app in front: close the popup, jump between entries or dictionaries, play audio, or add cards.
- **Pronunciation Audio**: Set your audio sources in **Settings → Yomitan Popup → Audio sources**. Click an entry's
  speaker icon to play the first recording found, or **right-click it** to choose from every recording your sources
  have. The one you play or pick there is also used when you add the word to Anki.

### Pausing the Game While You Read

Turn on **Pause the game while a popup is open** (*Settings → Scanning*) to freeze the game while you look words up,
so it can't move on without you: no auto-advance, no timed text, and its voice waits. It resumes when the popup
closes.

- The game is the app whose window you're capturing, or else the app in front. For a Windows game in Parallels, all
  of Windows pauses.
- It needs MacPopup's pause helper, which you allow once in *System Settings → General → Login Items*. The helper runs
  as root so it can pause Parallels, only pauses the game when MacPopup asks, and lets the game go on if MacPopup
  quits.
- **Pause and scan shortcut**: Press it in any app to pause the game and, with the OCR overlay, read its window right
  away, even while text is still appearing, so you can look up anything on screen. Press it again (or switch apps) to
  close the popup and let the game go on.

---

## Game Controllers

You can look up words and control popups with a game controller (DualShock 4, Switch Pro Controller, Xbox controllers
and others), without putting it down.

- **Set Up Your Controller**: In **Settings → Controllers**, connect your controller, click **Set Up…**, and press its
  buttons as shown. Once MacPopup knows its buttons, it can take over the controller while you look up words: your
  game doesn't react to it meanwhile, and doesn't see it disconnect. Only controllers that are set up are used.
- **Look Up Words**: In **Settings → Scanning**, record a **Controller scan key**, a button combination your game
  doesn't use, such as `L3 + R3`. Press it to start looking up words in the text box or the OCR text, and move with
  the D-pad or left stick. When you stop, the popup for that word opens (after the **Controller popup delay**, 1
  second by default). Press the combination again to close the popup and give the controller back to your game.
  - With **Scan resolution** set to **Character**, you move a character at a time and choose exactly where a word
    starts. With **Word**, you jump from word to word.
  - With the OCR overlay, you start in the dialogue box: on the latest WebSocket line if it's on screen, or else where
    the newest text begins. While text is still appearing, you start on its bottom or top sentence (**Controller
    starting position**, in *Settings → OCR Overlay*).
- **Control Popups**: Every shortcut in **Settings → Popup Shortcuts** can also have controller buttons (**Record
  Buttons**). While a popup is open, your game doesn't react to a controller that's set up; otherwise the buttons go
  to your game as usual.
- **Switching Apps**: Bringing another app to the front closes the popups and gives the controller back, so you can
  use it there. With **Pause the game while a popup is open** on, the game also stays paused while you look up words
  with the controller.
- **Other Shortcuts**: The sentence audio recording (*Settings → Anki Audio*) and the **Overlay hide key/buttons** and
  **Overlay switch key/buttons** (*Settings → General*) can have controller buttons too, which work at any time. As
  with the scan key, pick buttons your game doesn't use.

---

## OCR overlay

Switch to the OCR overlay with **OCR Overlay** in the menu bar, with **Overlay type** in *Settings → General*, or from
any app with the **Overlay switch key/buttons** set below it. The text box hides, and you can point at the text
in your game or app directly. Overlay options are in *Settings → OCR Overlay*, and how text is read (also by **Read
text from OCR**) in *Settings → OCR*. MacPopup needs the **Screen Recording** permission (*System Settings → Privacy &
Security*).

### Selecting a Window and Capture Areas

Choose **Select Captured Window…** in the menu bar (or click **Select…** next to **Captured window** in
*Settings → General*):

1. **Click the window** you want MacPopup to read, or **Whole Screen** for the entire screen.
2. **Optionally, drag over the areas where text appears**, then click **Done** (`Return`).
   - The first area is the **dialogue box**: MacPopup waits for its text to settle, and matches it with WebSocket
     lines.
   - **Other areas** (menus, choices, UI) are read as soon as they change.
   - **Undo** (`Delete`) removes the last area, **Other Window** picks another window, and **Cancel** (`Esc`) keeps
     your previous selection. Switching to another app or Space also takes you back to picking a window.

When you select again, the window you're reading comes to the front first (even from another Space), with its areas
already drawn.

MacPopup remembers the window by its app and title, even after a restart, including Windows apps in Parallels'
Coherence mode. It's only read while you can see it: on screen in the current Space, and not covered by other windows
(partly covered is fine). The window is also used for clean `{screenshot}`s on Anki cards, even in the Floating
Window.

### Reading the Dialogue

In the dialogue area, MacPopup waits for the text to stop changing before taking the line (**Text must stay unchanged
for**, in *Settings → OCR*), so text that types out or fades in is read in full, even over an animated background. You
don't have to wait to look words up: text that's still changing, scrolling or moving can be hovered too.

### OCR Engines

Choose the engine in **Settings → OCR → Text recognition engine**. Lines with none of your language's characters
(*Settings → General*) are skipped, such as an English menu in a Japanese game.

- **Live Text** *(default)*: Built into macOS. Reads the language set in *Settings → General*, plus English.
- **meikiocr**: Built-in Core ML models by rtr46, trained on Japanese video games. Faster than Live Text, with tighter
  boxes around each character (Japanese only).
- **PP-OCRv6 Manga**: Built-in Core ML models by Kellenok, fine-tuned from PaddleOCR's PP-OCRv6 for manga and anime:
  vertical text in speech bubbles, and sound effects (Japanese and Chinese).
- **mida + VOCR6**: Built-in Core ML models: rtr46's mida finds the lines and vita-vn-ocr's VOCR6 reads them, as in
  meikipop. Faster than meikiocr, for Japanese game text, horizontal and vertical.
- **Screen AI**: Google Chrome's own OCR engine, running on Core ML. Reads most scripts, and works out the layout and
  reading order by itself.
  - *Setup*: Make sure Chrome has downloaded its Screen AI component (`~/Library/Application
    Support/Google/Chrome/screen_ai`), run `scripts/convert-screenai.py` to make a `.zip` file, and load it with
    **Screen AI models → Load…**.
- **OneOCR**: The OCR engine of the Windows 11 Snipping Tool. Reads most scripts.
  - *Setup*: Run `scripts/convert-oneocr.py` on your decrypted OneOCR model files (`config.json` and `Model_Edge`) to
    make a `.zip` file, and load it with **OneOCR models → Load…**.
- **Cloud recognition (second pass)**: Optionally turn on **Google Lens** or **Bing**. Local OCR reads the text first,
  so popups stay quick; once a dialogue line settles, a picture of the dialogue area is sent to Google Lens or Bing for
  a more accurate reading. Lines matched with a WebSocket line keep the WebSocket text.

### Hybrid WebSocket + OCR Matching

With a text hooker (WebSocket) and the OCR overlay both running, and **Match and fix OCR with WebSocket text** on, you
get the best of both:

- You point at words on the game screen, where OCR found them, while MacPopup replaces misread characters with the
  exact text of the WebSocket line.
- It works with partial lines (such as sentences split over pages), and with games that show several lines at once
  (**Previous WebSocket lines to match**).
- In Japanese, furigana is left out (**Ignore furigana**), so the small readings above kanji don't get in the way.

---

## Anki Integration

MacPopup adds cards with your Yomitan profile's card settings, and fills in these markers from what you were reading:

- `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}`,
  `{sentence-furigana-plain}`: From the line you looked the word up in.
- `{screenshot}`: A clean picture of your **Captured window** (without overlays or windows covering it), or of the
  screen if no window is chosen or it isn't on screen. Taken at 1x, or at the display's Retina scale with **Screenshot
  resolution** set to Full Retina resolution (*Settings → Anki Screenshot*).
  With a captured window, MacPopup also takes a screenshot shortly after each new line and keeps the latest ones
  (**Screenshots to keep**, 20 by default), so a card shows the scene of its line even if the game has moved on. A card
  added from a popup inside a popup gets a picture of the popup you looked the word up in instead.
- `{document-title}`: The name of the app in front.
- `{clipboard-text}`, `{clipboard-image}`: What's on the clipboard. `{popup-selection-text}`: The text you selected in
  the popup.

> **Selected popup text in templates**: The Yomitan API can't see text you select in a MacPopup popup. If your card
> templates use it, turn on **Use local Handlebars templates** in *Settings → Anki* and import your Yomitan settings,
> so MacPopup fills in the templates itself. Templates read the selection with `getMedia "popupSelectionText"`, for
> example to pick a dictionary by selecting its name.

### Automatic Sentence Audio Recording

With **Settings → Anki Audio**, one shortcut after adding a card adds the character's voice line from your game:

1. MacPopup keeps the last few minutes of your game's audio in memory (**Keep game audio for the last**, 5 minutes by
   default; without a captured window, the audio of every app except MacPopup), along with when each line appeared (in
   the text box or through OCR). When you press the shortcut, it finds the line of the last card you added from a
   popup and cuts out its voice right away, using macOS's sound classifier to leave out music and sound effects. If the
   line is still being spoken, it waits for the voice to end.
2. If the line isn't there anymore (it's older than what's kept, or you moved on before the voice finished) and
   **Visual novel backlog capture** is on, MacPopup replays it instead: it brings your game to the front, presses your
   **Keys to open backlog**, records the voice while you replay it, then presses your **Keys to close backlog**. With
   **Automatically detect start and end of speech** on, recording stops when the voice ends, and nothing is saved if
   no voice is heard in time. With it off, press the shortcut again to stop.
3. The clip goes into the **Sentence audio field** (*Settings → Anki Audio*) of that card, and of any other cards you
   added from the same line, if that field is empty. You can have it played back afterwards. Cards added from a popup
   inside a popup don't get sentence audio.

If the game is paused (see [Pausing the Game](#pausing-the-game-while-you-read)) while the voice is still playing, the
audio is added once the game goes on. Windows games in Parallels' Coherence mode are recorded too.

To add a card and its voice in one go, Option-click a popup's add button (or use a popup shortcut set to **Add note
(sentence audio)**). If that overwrites an existing card, the recording replaces its sentence audio, unless **Replace
sentence audio when overwriting cards** is off (this also applies to audio from IINA).

MacPopup needs permission to record other apps' audio, which it asks for when you turn sentence audio on (*System
Settings → Privacy & Security → Screen & System Audio Recording*). Backlog capture also needs the **Accessibility**
permission (*Settings → Permissions*).

### Videos in IINA

The [IINA](https://iina.io) plugin in `iina-plugin/` sends the subtitles you're watching to MacPopup, and gives cards
made from them the line's own frame and audio:

1. Click **Install** in *Settings → IINA Integration* to open the plugin in IINA (or, for development, run
   `iina-plugin link iina-plugin` from IINA's `Contents/MacOS`), turn it on in IINA's *Settings → Plugins*, and
   restart IINA. The plugin asks for access to files, which it needs for live streams and cookies (see step 3).
2. Add `ws://localhost:6680` in MacPopup's *Settings → WebSockets* (you can change the port in the plugin's settings).
   Each subtitle arrives like a text hooker's line, so you can read it in the text box, or hover the subtitles on the
   video with the OCR overlay and **Match and fix OCR with WebSocket text** on.
3. For these lines, `{screenshot}` is the frame from the middle of the line, without subtitles, at the video's size,
   and the **Sentence audio field** (*Settings → Anki Audio*) gets the line's audio, padded as set in *Settings → IINA
   Integration*. You can turn either off there (**Use clean screenshots for cards**, **Use clean audio for cards**).
   This also works with network streams, including web videos IINA plays through yt-dlp: MacPopup fetches them with
   IINA's headers, cookies and proxy. For live streams, it takes the line from IINA's cache, which holds about the
   last minute played.

---

## iPhone App (Experiment)

`ios/` has an experimental iPhone app that reads pictures and the screen with the same OCR engines, and opens the text
in Safari for a dictionary extension such as Yomitan. It's separate from MacPopup: see [ios/README.md](ios/README.md).

---

## Reporting Problems

If something doesn't work right, turn on **Debug** (*Settings → General*) and use MacPopup until it happens again.
MacPopup then logs what it does (lines and OCR readings, popups, shortcuts, cards, Anki Audio and screenshots, the
controller and game pauses), with your settings (except your AnkiConnect key) and its version. **Option-click** the
setting to show the log in Finder, and attach `debug.jsonl` to your report. The log includes the text you've been
reading, and it's deleted when you turn Debug off.

With the OCR overlay, Debug also outlines the text MacPopup recognized: red while it's still changing, orange for local
OCR, gold for cloud OCR, and green for lines fixed with WebSocket text.

---

## Limitations compared to Yomitan

- **No prefix matching**: The Yomitan API only looks up exact terms.
- **No profile switching shortcuts**: Yomitan's shortcuts for switching profiles in a popup aren't supported.

---

## Building

You need Swift 5.9+ (the Xcode Command Line Tools) and Node.js 18+.

```sh
cd web && npm install && cd ..
scripts/build.sh            # Builds the release app at build/MacPopup.app
```

- `scripts/build.sh debug` makes a debug build.
- The first build downloads Yomitan's kanji stroke order font and libcurl-impersonate (for Google Lens and Bing), and
  builds a small ffmpeg (for IINA lines), which takes a few minutes. They're kept in `build/cache`.
- **Code signing**: To keep macOS from asking for the Screen Recording and Accessibility permissions again after each
  build, sign the app with your own certificate: put its name (as `security find-identity -v -p codesigning` lists it,
  e.g. "Apple Development: Your Name (TEAMID)") in a `.signing-identity` file at the top of the repository (it's kept
  out of git), or set `MACPOPUP_SIGN_IDENTITY`. Otherwise the app is signed ad hoc.
- **Notarization**: `scripts/notarize.sh` builds a notarized copy to share, in `build/notarized` (the app and a zip of
  it). It needs a "Developer ID Application" certificate (or `MACPOPUP_NOTARY_IDENTITY`) and a notarytool keychain
  profile (made with `xcrun notarytool store-credentials`), whose name goes in a `.notary-profile` file (kept out of
  git) or `MACPOPUP_NOTARY_PROFILE`.

---

## Support the project

If you like what I do, you can [Sponsor me here on GitHub](https://github.com/sponsors/AuroraWright)!

---

## License

Licensed under the **GPL-3.0**.

Large parts of the code are derived from [Yomitan](https://github.com/yomidevs/yomitan), with extra changes from the
[OwOtan](https://github.com/AuroraWright/owotan) fork (see `vendor/yomitan/README.md` and `LICENSE`).

The text box's line processing, settings and replacements are adapted from
[texthooker-ui](https://github.com/Renji-XD/texthooker-ui) under the **MIT License** (see `vendor/texthooker-ui/README.md`
and `vendor/texthooker-ui/LICENSE`).

The `meikiocr` Core ML models (`vendor/meikiocr`) are licensed under the **LGPL-3.0**, and
`Sources/OCREngines/MeikiOCR.swift` is adapted from `meikiocr` under the **Apache License 2.0** (see
`vendor/meikiocr/README.md`).

The PP-OCRv6 Manga Core ML models (`vendor/ppocr-manga`) are licensed under the **Apache License 2.0** (see
`vendor/ppocr-manga/README.md`).

The VOCR6 Core ML models and heads (`vendor/mida-vocr6`) are licensed under the **GPL-3.0-or-later**, for
**non-commercial use only**, and `Sources/OCREngines/MidaVOCR6.swift` is adapted from meikipop's provider and
vita-vn-ocr's code under the **GPL-3.0-or-later** (see `vendor/mida-vocr6/README.md`). The mida model is by rtr46.

The speech recognition models for **Read text from audio** don't come with MacPopup: the `scripts/convert-*.py`
scripts download them from their authors. Kitsune is licensed under **CC BY-NC 4.0** (**non-commercial use only**),
SenseVoice under the FunASR model licence, Parakeet under **CC BY 4.0**, and Whisper, anime-whisper and SaT under the
**MIT License**. Whisper runs with Argmax's [WhisperKit](https://github.com/argmaxinc/WhisperKit) (**MIT License**).
Live Caption's language packs are Google's: `scripts/convert-soda.py` downloads them from Chrome's update server for
your own use only (don't share them or the `.zip` file). MacPopup runs them itself (`Sources/SODA`), without Chrome.
