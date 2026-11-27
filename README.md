# MacPopup

<img src="Resources/AppIcon.png" alt="MacPopup’s icon" width="128" align="right">

The creatively named MacPopup is a native macOS overlay for looking up words with
[Yomitan](https://github.com/yomidevs/yomitan) and making Anki cards, even over full-screen games, visual novels and
videos.

It has two ways to read:

- **Floating Window** *(inspired by [JL](https://github.com/rampaa/JL) and
  [texthooker-ui](https://github.com/Renji-XD/texthooker-ui))*: Shows lines in a floating text box you can customize.
  They come from WebSockets (from tools such as Textractor, Agent or LunaTranslator), your clipboard, OCR of a game's
  window, or its voices.
- **OCR Overlay** *(inspired by [meikipop](https://github.com/rtr46/meikipop) and
  [GameSentenceMiner](https://github.com/bpwhelan/GameSentenceMiner))*: Reads the text straight from any game or app
  window, so you can point at words right on screen. It uses Apple Live Text,
  [meikiocr](https://github.com/rtr46/meikiocr), [PP-OCRv6 Manga](https://huggingface.co/Kellenok/PP-OCRv6_manga),
  [mida](https://huggingface.co/rtr46/mida) + [VOCR6](https://github.com/bee-san/vita-vn-ocr), Chrome's Screen AI or
  Windows' OneOCR, optionally followed by Google Lens or Bing for a second, more accurate reading.

Lookups and Anki card templates come from the Yomitan you already use in your browser, through the [Yomitan
API](https://github.com/yomidevs/yomitan-api), which MacPopup can install for you.

---

## Contents

- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [Floating Window](#floating-window)
- [Looking Up Words and Using Popups](#looking-up-words-and-using-popups)
- [Game Controllers](#game-controllers)
- [OCR Overlay](#ocr-overlay)
- [Anki Integration](#anki-integration)
- [Experimental iPhone App](#experimental-iphone-app)
- [Reporting Problems](#reporting-problems)
- [Limitations Compared to Yomitan](#limitations-compared-to-yomitan)
- [Building from Source](#building-from-source)
- [Support the Project](#support-the-project)
- [License and Acknowledgments](#license-and-acknowledgments)

---

## Requirements

- **macOS 15 (Sequoia)** or later on an **Apple Silicon Mac**
- **Yomitan** in Chrome, Chromium, Brave or Firefox, with the [Yomitan API](https://github.com/yomidevs/yomitan-api)
  (`http://127.0.0.1:19633` by default; see [Connect Yomitan](#2-connect-yomitan))
- **Anki** with the **AnkiConnect** add-on, to make cards

---

## Getting Started

### 1. Launch MacPopup

MacPopup runs in the background, without a Dock icon. The first time, a welcome window helps you connect to the Yomitan
API and give MacPopup the macOS permissions it needs.

Click the **speech bubble icon** in the menu bar to switch between **Floating Window** and **OCR Overlay**, choose the
window to read (**Select Captured Window…**), **Hide Overlays** or **Move to Next Display**, or open **Settings…**,
**Reload** or **Quit MacPopup**. To hide or show the overlay from any app, even a full-screen game, set **Overlay hide
key/buttons** in *Settings → General*.

### 2. Connect Yomitan

1. In *Settings → Scanning*, click **Install** next to **Yomitan API URL**. This installs MacPopup's own version of the
   Yomitan API for Chrome, Chromium, Brave or Firefox (no Python needed).
2. Restart your browser.
3. In Yomitan's settings, turn on **Advanced** at the bottom of the sidebar, then **Enable Yomitan API** under
   *General*.

### 3. Import Your Settings

Instead of setting MacPopup up from scratch, click **Import** at the bottom of the Settings sidebar:

- **Yomitan Settings…**: A Yomitan backup (*Yomitan Settings → Backup → Export Settings*), and a profile if it has
  several: your language, popup look, custom CSS, dictionary styles and collapse rules, scanning settings, audio
  sources, popup shortcuts, Anki settings and card templates.
- **texthooker-ui Settings…**: A texthooker-ui export: your text box theme, font size, line settings and text
  replacements.
- **MacPopup Settings…**: A file saved with **Export → MacPopup Settings…**. It replaces all your current settings.

> [!NOTE]
> If your Yomitan shares its settings through its API (not in a Yomitan release yet), there's nothing to import: popups
> follow your Yomitan's look, dictionaries and collapse rules, and stay in sync with it. To use MacPopup's own look
> instead, turn off **Use Yomitan's display settings** in *Settings → Yomitan Popup*. With an older Yomitan, MacPopup
> uses what you imported.

---

## Floating Window

The Floating Window shows lines from every WebSocket in *Settings → WebSockets* (`ws://localhost:6677` by default), as
plain text or texthooker-ui JSON (`{"sentence": "..."}`).

### The Text Box

- **Move & Resize**: Drag the box by its top edge, and resize it from its bottom-right corner.
- **Buttons**: Hover over the box for buttons that turn clipboard reading, OCR or audio on and off, pause new lines,
  clear the box, open Settings, or hide the overlay.
- **Keep Lines**: Turn on **Keep lines after quitting** (*Settings → Floating Window*) to get the box's lines back the
  next time MacPopup opens; clearing the box clears them too. To save lines to a file or bring them back from one, use
  **Export** and **Import → Floating Window Lines…** in the Settings sidebar.

### Other Sources of Lines

- **Read copied text from clipboard** (*Settings → Floating Window*): Adds text you copy in other apps, except passwords
  from password managers.
- **Read text from OCR** (*Settings → Floating Window*, or the **OCR** button): Reads your dialogue area with OCR, like
  a text hooker, or the whole window if you haven't drawn one (see [Selecting a Window and Capture
  Areas](#selecting-a-window-and-capture-areas)). As a page fills up, as in visual novels, each new sentence becomes a
  line, skipping lines that already came over WebSocket; lines read in the OCR Overlay are added too. A hidden window
  may not be readable.
- **Read text from audio** (*Settings → Floating Window*, or the **audio** button): Adds what's said in the captured
  window's app (or any app, if no window is captured), a sentence per line, leaving out music and sound effects. It
  needs the **System Audio Recording** permission (*Screen & System Audio Recording* in System Settings).

### Models for Read Text from Audio

The speech recognition models run on your Mac and don't come with MacPopup. In *Settings → Transcription*, choose a
model, make its `.zip` file with its script in `scripts/`, and click **Load**:

| Model | Script | Languages and notes |
| --- | --- | --- |
| **Live Caption** *(default)* | `scripts/convert-soda.py` | 16 languages: Chrome's speech recognition. Fast, with punctuation |
| **Kitsune** | `scripts/convert-kitsune.py` | Japanese. Very fast and accurate |
| **SenseVoice** | `scripts/convert-sensevoice.py` | Chinese, Cantonese, Japanese, Korean and English. The fastest |
| **Parakeet** | `scripts/convert-parakeet.py` | 25 European languages. Very fast, and finds the language itself |
| **Whisper** | `scripts/convert-whisper.py` | 99 languages. About a second per line; `--full` makes the slightly more accurate 1.6 GB build |
| **anime-whisper** | `scripts/convert-anime-whisper.py` | Japanese. The most accurate for game and anime voices, but slower |

**Lines**:

- A new line starts when the speaker pauses (**Line ends after a pause of**, 1000 ms by default).
- To end lines where sentences end, which is more accurate, turn on **Detect sentence ends**, load **SaT** the same way
  (`scripts/convert-sat.py`), and set **Line ends after a pause of** to `200`.
- Turn on **Show words as they're heard** to see words as they're spoken *(not available with Whisper and
  anime-whisper)*.

### Look & Text

- **Font & Formatting**: Pick the font, size, color, underline, strikethrough, shadow and background in the macOS Fonts
  panel (*Settings → Floating Window → Font*), along with the theme, background opacity, line spacing and custom CSS.
- **Reading**: Show furigana above words (hiragana, katakana, romaji or the dictionary reading), add spaces between
  words, show text vertically (**Vertical text layout**), or hide duplicate lines and lines that aren't in your
  language.
- **Text Replacements**: Clean up incoming lines with regular-expression find-and-replace rules, applied in order
  (*Settings → General → Text replacements*); the test field under the list shows what they do to a sample line. With
  the OCR Overlay, they apply to WebSocket lines before those are matched with the text on screen.

---

## Looking Up Words and Using Popups

MacPopup aims to be a "system-wide Yomitan": popups that look and work like Yomitan's in your browser, with your
dictionaries, settings and Anki templates, over any app or game.

- **Hover to Look Up**: Point at a word to open a popup, with no key by default. You can require `Option`, `Control`,
  `Shift` or `Command`, or combine keys and mouse buttons with **Other** in *Settings → Scanning* (for example `shift
  -mouse0` or `alt kanji`).
- **Nested Popups**: Hold `Shift` (or the key you set) over a word in a popup to open another one. Or turn on **Search
  terms when clicking text from the results list** to search in the same popup, or **Allow scanning popup source terms**
  to look up headwords.
- **Mouse Navigation**:
  - `Option` + scroll: Move between entries.
  - `Shift` + scroll, or the mouse's **Back / Forward** buttons: Go back and forward through your lookups.
  - Click outside the popup to close it.
- **Popup Shortcuts**: The shortcuts in *Settings → Popup Shortcuts* work while a popup is open, even with a game or
  another app in front: close the popup, jump between entries or dictionaries, play audio, or add cards.
- **Pronunciation Audio**: Set your sources in *Settings → Yomitan Popup → Audio sources*. Click an entry's speaker icon
  to play the first recording found, or **right-click** it to pick from all of them. The one you play or pick is also
  used for Anki cards.

### Pausing the Game While You Read

Turn on **Pause the game while a popup is open** in *Settings → Scanning* so the game waits while you look words up: no
auto-advance, no timed choices, and no voice until the popup closes. The game is the app whose window you're capturing,
or else the app in front; for a Windows game in Parallels, all of Windows pauses.

- **Pause helper**: Allow it once in *System Settings → General → Login Items*. It runs as root so it can pause
  Parallels, only pauses the game when MacPopup asks, and lets the game go on if MacPopup quits.
- **Pause and scan shortcut**: Press it in any app to pause the game and, with the OCR Overlay, read its window right
  away, even while text is still appearing. Press it again (or switch apps) to close the popup and let the game go on.

---

## Game Controllers

You can look up words and control popups with a game controller (DualShock 4, Switch Pro Controller, Xbox controllers
and others):

- **Set Up Your Controller**: Connect it, click **Set Up…** in *Settings → Controllers*, and press its buttons as shown.
  MacPopup only uses controllers that are set up. While you look up words, your game doesn't react to the controller,
  and doesn't see it disconnect.
- **Look Up Words**: Record a **Controller scan key** in *Settings → Scanning*, with buttons your game doesn't use (such
  as `L3 + R3`). Press it, then move through the text box or OCR text with the D-pad or left stick; when you stop, that
  word's popup opens (after the **Controller popup delay**, 1 second by default). Press it again, or switch apps, to
  close the popup and give the controller back. With **Pause the game while a popup is open** on, the game stays paused
  meanwhile.
  - **Scan resolution**: **Character** moves a character at a time; **Word** jumps from word to word.
  - **Where you start with the OCR Overlay**: In the dialogue box, on the latest WebSocket line if it's on screen, or
    else where the newest text begins. While text is still appearing, on its bottom or top sentence (**Controller
    starting position**, *Settings → OCR Overlay*).
- **Other Shortcuts**: Every shortcut in *Settings → Popup Shortcuts*, **Recording key/buttons** (*Settings → Anki
  Audio*), and **Overlay hide key/buttons** and **Overlay switch key/buttons** (*Settings → General*) can have
  controller buttons too (**Record Buttons**). Popup shortcuts' buttons only work while a popup is open, when your game
  doesn't react to the controller; the others always reach your game, so pick buttons it doesn't use.

---

## OCR Overlay

Switch to the OCR Overlay with **OCR Overlay** in the menu bar, **Overlay type** in *Settings → General*, or **Overlay
switch key/buttons** from any app: the text box hides, and you point at the text in your game or app directly. Its
options are in *Settings → OCR Overlay*, and how text is read in *Settings → OCR*. It needs the **Screen Recording**
permission (*System Settings → Privacy & Security*).

### Selecting a Window and Capture Areas

Choose **Select Captured Window…** in the menu bar, click **Select…** next to **Captured window** in *Settings →
General*, or press your **Select captured window key** in any app:

1. **Choose the window**: Click the window to read, or **Whole Screen**.
2. **Draw capture areas *(optional)***: Drag over the areas where text appears, then click **Done** (`Return`).
   - The **first area** is the **dialogue box**: MacPopup waits for its text to settle, and matches it with WebSocket
     lines.
   - **Other areas** (menus, choices, UI) are read as soon as they change.
   - **Undo** (`Delete`) removes the last area, **Other Window** picks another window, and **Cancel** (`Esc`) keeps your
     previous selection. Switching to another app or Space also takes you back to picking a window.

Selecting again brings the window you're reading to the front (even from another Space), with its areas already drawn.
MacPopup remembers the window by its app and title across restarts, including Windows apps in Parallels' Coherence mode,
and reads it only while you can see it: in the current Space, and not fully covered by other windows. It also gives
clean `{screenshot}`s for Anki cards, and its app's audio is used for sentence audio and **Read text from audio**.

### Reading the Dialogue

In the dialogue area, MacPopup waits for the text to stop changing (**Text must stay unchanged for**, *Settings → OCR*),
so text that types out or fades in is read in full, even over an animated background. Meanwhile, text that's still
changing, scrolling or moving can be hovered too.

### OCR Engines

Choose the engine in *Settings → OCR → Text recognition engine*. Lines with none of your language's characters
(*Settings → General → Language*) are skipped, such as an English menu in a Japanese game.

| Engine | Languages | Notes |
| --- | --- | --- |
| **Live Text** *(default)* | Your language, plus English | Built into macOS |
| **meikiocr** | Japanese | Built-in models by rtr46, trained on Japanese games. Faster than Live Text, with tighter character boxes |
| **PP-OCRv6 Manga** | Japanese, Chinese | Built-in models by Kellenok, fine-tuned from PP-OCRv6 for manga and anime: vertical speech bubbles and sound effects |
| **mida + VOCR6** | Japanese | Built-in models (rtr46's mida and vita-vn-ocr's VOCR6, as in meikipop) for horizontal and vertical game text. Faster than meikiocr |
| **Screen AI** | Most scripts | Google Chrome's own OCR engine, run with Core ML. Needs setup (below) |
| **OneOCR** | Most scripts | The OCR engine of the Windows 11 Snipping Tool. Needs setup (below) |

- **Screen AI setup**: Make sure Chrome has downloaded its Screen AI component (`~/Library/Application
  Support/Google/Chrome/screen_ai`), run `scripts/convert-screenai.py`, and load the `.zip` file with **Screen AI models
  → Load…**.
- **OneOCR setup**: Run `scripts/convert-oneocr.py` on your decrypted OneOCR model files (`config.json` and
  `Model_Edge`), and load the `.zip` file with **OneOCR models → Load…**.
- **Cloud recognition (second pass)**: Optionally turn on **Google Lens** or **Bing** (*Settings → OCR*). Local OCR
  reads the text first, so popups stay quick; once a dialogue line settles, a picture of the dialogue area is sent to
  Google Lens or Bing for a more accurate reading. Lines matched with a WebSocket line keep its text.

### WebSocket + OCR Matching

With a text hooker (WebSocket) and the OCR Overlay both running, and **Match and fix OCR with WebSocket text** on:

- You point at words where OCR found them on screen, while MacPopup replaces misread characters with the WebSocket
  line's exact text.
- Partial lines, such as sentences split over pages, work too, as do games that show several lines at once (**Previous
  WebSocket lines to match**).
- In Japanese, **Ignore furigana** leaves out the small readings above kanji, so they don't get in the way.

---

## Anki Integration

MacPopup adds cards with your Yomitan profile's deck, note type and fields, and fills in these markers from what you
were reading:

- **Sentence**: `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}` and
  `{sentence-furigana-plain}`, from the line you looked the word up in.
- **`{screenshot}`**: A clean picture of your **Captured window** (without overlays or windows covering it), or of the
  screen if there's none on screen, at 1x or Retina scale (**Screenshot resolution**, *Settings → Anki Screenshot*).
  With a captured window, MacPopup keeps one for each recent line (**Screenshots to keep**, 20 by default), so a card
  shows its line's scene even after the game moves on. Cards from a nested popup get a picture of the popup.
- **Other**: `{document-title}` (the app in front), `{clipboard-text}` and `{clipboard-image}`, and
  `{popup-selection-text}` (the text you selected in the popup).

> [!TIP]
> **Selected popup text in templates**: The Yomitan API can't see text you select in a MacPopup popup. If your card
> templates use it (for example `getMedia "popupSelectionText"`), turn on **Use local Handlebars templates** in
> *Settings → Anki* and import your Yomitan settings, so MacPopup fills in the templates itself.

### Automatic Sentence Audio Recording

With *Settings → Anki Audio*, one shortcut after adding a card adds the character's voice line from your game:

1. **From the recorded audio**: MacPopup keeps the last few minutes of your game's audio in memory (**Record game audio
   for the last**, 5 minutes by default; without a captured window, every app's audio but MacPopup's), with when each
   line appeared. The shortcut finds the line of your last card from a popup and cuts out its voice, leaving out music
   and sound effects with macOS's sound classifier, and waiting for the voice to end if it's still playing.
2. **From the backlog**: If the line isn't in the recorded audio anymore and **Visual novel backlog capture** is on,
   MacPopup brings your game to the front, presses your **Keys to open backlog and replay voice**, records the voice as
   it replays, then presses your **Keys to close backlog**. With **Automatically detect start and end of speech** on,
   recording stops when the voice ends, and nothing is saved if no voice is heard in time; with it off, press the
   shortcut again to stop.
3. **Into the card**: The clip goes into the **Sentence audio field** of that card and of other cards from the same
   line, where it's empty, and can be played back afterwards. Cards from a nested popup don't get one.

- **Add and record in one go**: Option-click a popup's add button (or use a popup shortcut set to **Add note (sentence
  audio)**). If that overwrites a card, the recording replaces its sentence audio, unless **Replace sentence audio when
  overwriting cards** is off (this also applies to audio from IINA).
- **Paused games and Parallels**: If the game is paused (see [Pausing the Game](#pausing-the-game-while-you-read)) while
  the voice is still playing, the audio is added once the game goes on. Windows games in Parallels' Coherence mode are
  recorded too.
- **Permissions**: MacPopup asks to record other apps' audio when you turn sentence audio on (*Screen & System Audio
  Recording* in System Settings). Backlog capture also needs **Accessibility** (*Settings → Permissions*).

### Videos in IINA

The [IINA](https://iina.io) plugin in `iina-plugin/` sends the subtitles you're watching to MacPopup, gives cards made
from them the line's own frame and audio, and can transcribe videos without subtitles:

1. **Install the plugin**: Click **Install** in *Settings → IINA Integration* to open the plugin in IINA (or, for
   development, run `iina-plugin link iina-plugin` from IINA's `Contents/MacOS`), turn it on in IINA's *Settings →
   Plugins*, and restart IINA. The plugin asks for access to files, which it needs for live streams and cookies.
2. **Connect it**: Add `ws://localhost:6680` in *Settings → WebSockets* (the port can be changed in the plugin's
   settings). Each subtitle arrives like a text hooker's line: read it in the Floating Window, or hover the subtitles on
   the video with the OCR Overlay and **Match and fix OCR with WebSocket text** on.
3. **Clean screenshots and audio**: For these lines, `{screenshot}` is the line's middle frame without subtitles, at the
   video's size, and the **Sentence audio field** gets the line's audio, padded as set in *Settings → IINA Integration*
   (where **Use clean screenshots for cards** and **Use clean audio for cards** turn them off). Network streams work
   too, including web videos IINA plays through yt-dlp (fetched with IINA's headers, cookies and proxy), and live
   streams, from IINA's cache of about the last minute.
4. **Transcribe videos without subtitles**: Turn on **Transcribe videos without subtitles** (*Settings → IINA
   Integration*). MacPopup transcribes ahead of where you're watching, with the model in *Settings → Transcription*,
   into a **MacPopup transcription** subtitle track that works like any other. It stops if you add a subtitle file in
   your language, doesn't work with live streams, and pauses **Read text from audio** meanwhile. Transcriptions are
   saved, so videos aren't transcribed twice; **Clear…** next to **Saved transcriptions** deletes them.

---

## Experimental iPhone App

`ios/` has a separate, experimental iPhone app (iOS 18 or later) that reads pictures and the screen with the same OCR
engines, and opens the text in Safari for a dictionary extension such as Yomitan. See [ios/README.md](ios/README.md) for
setup and use.

---

## Reporting Problems

Turn on **Debug** (*Settings → General*) and use MacPopup until the problem happens again. It logs lines and OCR
readings, popups, shortcuts, cards, Anki Audio and screenshots, the controller and game pauses, with your settings
(except your AnkiConnect key) and its version.

- **Option-click** the **Debug** setting to show `debug.jsonl` in Finder, and attach it to your report. The log includes
  the text you've been reading, and it's deleted when you turn **Debug** off.
- With the OCR Overlay, **Debug** also outlines the text MacPopup recognized: **red** while it's still changing,
  **orange** for local OCR, **gold** for cloud OCR, and **green** for lines fixed with WebSocket text.

---

## Limitations Compared to Yomitan

- **No prefix matching**: The Yomitan API only looks up exact terms.
- **No profile switching shortcuts**: Yomitan's shortcuts for switching profiles in a popup aren't supported.

---

## Building from Source

You need Swift 5.9+ (the Xcode Command Line Tools) and Node.js 18+ on an Apple Silicon Mac:

```sh
cd web && npm install && cd ..
scripts/build.sh            # The release app, at build/MacPopup.app
scripts/build.sh debug      # A debug build
```

- **First build**: It downloads Yomitan's kanji stroke order font and libcurl-impersonate (for Google Lens and Bing),
  and builds a small ffmpeg (for IINA lines), into `build/cache`. This takes a few minutes.
- **Code signing**: So macOS doesn't ask for Screen Recording and Accessibility again after each build, sign with your
  own certificate: put its name (as `security find-identity -v -p codesigning` lists it, for example "Apple Development:
  Your Name (TEAMID)") in a `.signing-identity` file at the top of the repository (kept out of git), or set
  `MACPOPUP_SIGN_IDENTITY`. Otherwise the app is signed ad hoc.
- **Notarization**: `scripts/notarize.sh` makes a notarized app and a zip of it to share, in `build/notarized`. It needs
  a "Developer ID Application" certificate (or `MACPOPUP_NOTARY_IDENTITY`) and a notarytool keychain profile (made with
  `xcrun notarytool store-credentials`), named in a `.notary-profile` file (kept out of git) or
  `MACPOPUP_NOTARY_PROFILE`.

---

## Support the Project

If you like what I do, you can [Sponsor me here on GitHub](https://github.com/sponsors/AuroraWright)!

---

## License and Acknowledgments

MacPopup is licensed under the **GPL-3.0** (`LICENSE`).

- **Yomitan and OwOtan**: Large parts of the code are derived from [Yomitan](https://github.com/yomidevs/yomitan), with
  changes from the [OwOtan](https://github.com/AuroraWright/owotan) fork (see `vendor/yomitan/README.md` and `LICENSE`).
- **texthooker-ui**: The text box's line processing, settings and replacements are adapted from
  [texthooker-ui](https://github.com/Renji-XD/texthooker-ui) under the **MIT License** (see
  `vendor/texthooker-ui/README.md` and `vendor/texthooker-ui/LICENSE`).
- **meikiocr**: The Core ML models (`vendor/meikiocr`) are under the **LGPL-3.0**, and
  `Sources/OCREngines/MeikiOCR.swift` is adapted from `meikiocr` under the **Apache License 2.0** (see
  `vendor/meikiocr/README.md`).
- **PP-OCRv6 Manga**: The Core ML models (`vendor/ppocr-manga`) are under the **Apache License 2.0** (see
  `vendor/ppocr-manga/README.md`).
- **mida + VOCR6**: The VOCR6 Core ML models and heads (`vendor/mida-vocr6`) are under the **GPL-3.0-or-later**, for
  **non-commercial use only**, and `Sources/OCREngines/MidaVOCR6.swift` is adapted from meikipop's provider and
  vita-vn-ocr's code under the **GPL-3.0-or-later** (see `vendor/mida-vocr6/README.md`). The mida model is by rtr46.
- **Speech recognition models**: They don't come with MacPopup; the `scripts/convert-*.py` scripts download them from
  their authors.
  - **Kitsune**: **CC BY-NC 4.0** (**non-commercial use only**)
  - **SenseVoice**: the FunASR model license
  - **Parakeet**: **CC BY 4.0**
  - **Whisper**, **anime-whisper** and **SaT**: **MIT License** (Whisper runs with Argmax's
    [WhisperKit](https://github.com/argmaxinc/WhisperKit), **MIT License**)
  - **Live Caption**: Google's language packs, which `scripts/convert-soda.py` downloads from Chrome's update server for
    **your own use only** (don't share them or the `.zip` file). MacPopup runs them itself (`Sources/SODA`), without
    Chrome.
