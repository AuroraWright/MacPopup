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

MacPopup runs in the background, without a Dock icon. The first time, a welcome window helps you check the Yomitan API
connection and give MacPopup the macOS permissions it needs.

Click the **speech bubble icon** in the menu bar at any time to:

- Switch between **Floating Window** and **OCR Overlay**
- Choose the window to read (**Select Captured Window…**)
- **Hide Overlays** / **Show Overlays**, or **Move to Next Display**
- Open **Settings…**, **Reload**, or **Quit MacPopup**

To hide or show the overlay from any app, even a full-screen game, set a keyboard shortcut or controller buttons for
**Overlay hide key/buttons** in *Settings → General*.

### 2. Connect Yomitan

1. In *Settings → Scanning*, click **Install** next to **Yomitan API URL**. This installs MacPopup's own version of the
   Yomitan API for Chrome, Chromium, Brave or Firefox (it doesn't need Python).
2. Restart your browser.
3. In Yomitan's settings, turn on **Advanced** at the bottom of the sidebar, then turn on **Enable Yomitan API** under
   *General*.

### 3. Import Your Settings

You don't have to set MacPopup up from scratch: click **Import** at the bottom of the Settings sidebar.

- **Yomitan Settings…**: Choose a Yomitan settings backup (*Yomitan Settings → Backup → Export Settings*), and a profile
  if it has several. This brings over your language, popup theme and size, custom CSS, dictionary styles and collapse
  rules, scanning settings, audio sources, popup shortcuts, Anki settings and card templates.
- **texthooker-ui Settings…**: Choose a texthooker-ui export to bring over your text box theme, font size, line settings
  and text replacements.
- **MacPopup Settings…**: Restore a file saved with **Export → MacPopup Settings…**. This replaces all your current
  settings.

> [!NOTE]
> If your Yomitan shares its settings through its API (not in a Yomitan release yet), you don't need to import anything:
> popups follow your Yomitan's look, dictionaries and collapse rules, and stay in sync when you change them there. To
> use MacPopup's own look instead, turn off **Use Yomitan's display settings** in *Settings → Yomitan Popup*. With an
> older Yomitan, MacPopup uses what you imported.

---

## Floating Window

The Floating Window shows the lines from every WebSocket listed in *Settings → WebSockets* (`ws://localhost:6677` by
default), as plain text or texthooker-ui JSON (`{"sentence": "..."}`).

### The Text Box

- **Move & Resize**: Drag the box by its top edge, and resize it from its bottom-right corner.
- **Buttons**: Hover over the box to show buttons above its top-right corner: turn clipboard reading, OCR or audio on
  and off, pause new lines, clear the box, open Settings, or hide the overlay.
- **Keep Lines**: Turn on **Keep lines after quitting** in *Settings → Floating Window* to see the box's lines again the
  next time MacPopup opens. Clearing the box also clears the saved lines. To save lines to a file, or bring them back
  from one, use **Export** and **Import → Floating Window Lines…** at the bottom of the Settings sidebar.

### Other Sources of Lines

Besides WebSockets, lines can come from:

- **Read copied text from clipboard** (*Settings → Floating Window*): Adds text you copy in other apps. Passwords copied
  from password managers are skipped.
- **Read text from OCR** (*Settings → Floating Window*, or the **OCR** button): Reads the game's text with OCR, like a
  text hooker. It reads your dialogue area, or the whole window if you haven't drawn one (see [Selecting a Window and
  Capture Areas](#selecting-a-window-and-capture-areas)). When a page fills up over time, as in visual novels, each new
  sentence or paragraph becomes its own line, and lines that already came over WebSocket aren't added twice. Lines read
  while you use the OCR Overlay are added too, so they're there when you switch back. A window may not be readable while
  it's hidden.
- **Read text from audio** (*Settings → Floating Window*, or the **audio** button): Adds what's said in the captured
  window's app (or in any app, if no window is captured), a sentence per line. Music and sound effects are skipped.
  MacPopup needs the **System Audio Recording** permission (*Screen & System Audio Recording* in System Settings).

### Models for Read Text from Audio

The speech recognition models run on your Mac and don't come with MacPopup. In *Settings → Transcription*, choose a
model, make its `.zip` file with its script in `scripts/`, and click **Load**:

| Model | Script | Languages and notes |
| --- | --- | --- |
| **Live Caption** *(default)* | `scripts/convert-soda.py` | 16 languages: Chrome's speech recognition. Fast, with punctuation |
| **Kitsune** | `scripts/convert-kitsune.py` | Japanese. Very fast and accurate |
| **SenseVoice** | `scripts/convert-sensevoice.py` | Chinese, Cantonese, Japanese, Korean and English. The fastest |
| **Parakeet** | `scripts/convert-parakeet.py` | 25 European languages. Very fast, and finds the language itself |
| **Whisper** | `scripts/convert-whisper.py` | 99 languages. About a second per line; `--full` makes the full 1.6 GB build (slightly more accurate) |
| **anime-whisper** | `scripts/convert-anime-whisper.py` | Japanese. The most accurate for game and anime voices, but slower |

**Lines**:

- A new line starts when the speaker pauses (**Line ends after a pause of**, 1000 ms by default).
- To end lines where sentences end instead, which is also more accurate, turn on **Detect sentence ends**, load the
  **SaT** model the same way (`scripts/convert-sat.py`), and set **Line ends after a pause of** to `200`.
- To see the words as they're spoken, turn on **Show words as they're heard** *(not available with Whisper and
  anime-whisper)*.

### Look & Text

- **Font & Formatting**: Pick the box's font, size, color, underline, strikethrough, shadow and background in the macOS
  Fonts panel (*Settings → Floating Window → Font*), along with the theme, background opacity, line spacing and custom
  CSS.
- **Reading**: Show furigana above words (in hiragana, katakana, romaji or the dictionary reading), add spaces between
  words, show text vertically (**Vertical text layout**), or hide duplicate lines and lines that aren't in your
  language.
- **Text Replacements**: Clean up incoming lines with regular-expression find-and-replace rules, applied in order
  (*Settings → General → Text replacements*). The test field under the list shows what your rules do to a sample line.
  With the OCR Overlay, they're applied to WebSocket lines before those are matched with the text on screen.

---

## Looking Up Words and Using Popups

MacPopup aims to be a "system-wide Yomitan": its popups look and work like Yomitan's in your browser, with your
dictionaries, settings and Anki templates, over any app or game.

- **Hover to Look Up**: Point at a word to open a popup. No key is needed by default. You can require one (`Option`,
  `Control`, `Shift` or `Command`), or choose **Other** in *Settings → Scanning* to combine keys and mouse buttons (for
  example `shift -mouse0` or `alt kanji`).
- **Nested Popups**: Hold `Shift` (or the key you set) while pointing at a word in a popup to open another popup. You
  can also turn on **Search terms when clicking text from the results list** to search within the same popup, or **Allow
  scanning popup source terms** to look up headwords too.
- **Mouse Navigation**:
  - `Option` + scroll: Move between entries.
  - `Shift` + scroll, or the mouse's **Back / Forward** buttons: Go back and forward through your lookups.
  - Click outside the popup to close it.
- **Popup Shortcuts**: The shortcuts in *Settings → Popup Shortcuts* work while a popup is open, even with a game or
  another app in front: close the popup, jump between entries or dictionaries, play audio, or add cards.
- **Pronunciation Audio**: Set your sources in *Settings → Yomitan Popup → Audio sources*. Click an entry's speaker icon
  to play the first recording found, or **right-click** it to choose from every recording your sources have. The one you
  play or pick is also used when you add the word to Anki.

### Pausing the Game While You Read

Turn on **Pause the game while a popup is open** in *Settings → Scanning* to freeze the game while you look words up, so
it can't move on without you: no auto-advance, no timed choices, and its voice waits. It resumes when the popup closes.

- The game is the app whose window you're capturing, or else the app in front. For a Windows game in Parallels, all of
  Windows pauses.
- It needs MacPopup's **Pause helper**, which you allow once in *System Settings → General → Login Items*. The helper
  runs as root so it can pause Parallels, only pauses the game when MacPopup asks, and lets the game go on if MacPopup
  quits.
- **Pause and scan shortcut**: Press it in any app to pause the game and, with the OCR Overlay, read its window right
  away, even while text is still appearing, so you can look up anything on screen. Press it again (or switch apps) to
  close the popup and let the game go on.

---

## Game Controllers

You can look up words and control popups with a game controller (DualShock 4, Switch Pro Controller, Xbox controllers
and others), without putting it down.

- **Set Up Your Controller**: Connect it, go to *Settings → Controllers*, click **Set Up…**, and press its buttons as
  shown. MacPopup only uses controllers that are set up. While you look up words, it takes over the controller: your
  game doesn't react to it meanwhile, and doesn't see it disconnect.
- **Look Up Words**: In *Settings → Scanning*, record a **Controller scan key**, a button combination your game doesn't
  use (such as `L3 + R3`). Press it to start looking up words in the text box or the OCR text, and move with the D-pad
  or left stick. When you stop, the popup for that word opens (after the **Controller popup delay**, 1 second by
  default). Press the combination again to close the popup and give the controller back to your game.
  - **Scan resolution**: With **Character**, you move a character at a time and choose exactly where a word starts. With
    **Word**, you jump from word to word.
  - **Where you start with the OCR Overlay**: In the dialogue box, on the latest WebSocket line if it's on screen, or
    else where the newest text begins. While text is still appearing, you start on its bottom or top sentence
    (**Controller starting position**, in *Settings → OCR Overlay*).
- **Control Popups**: Every shortcut in *Settings → Popup Shortcuts* can also have controller buttons (**Record
  Buttons**). While a popup is open, your game doesn't react to the controller; once it's closed, the buttons go to your
  game as usual.
- **Switching Apps**: Bringing another app to the front closes the popups and gives the controller back. With **Pause
  the game while a popup is open** on, the game also stays paused while you look up words with the controller.
- **Other Shortcuts**: **Recording key/buttons** (*Settings → Anki Audio*), **Overlay hide key/buttons** and **Overlay
  switch key/buttons** (*Settings → General*) can have controller buttons too, which work at any time. As with the scan
  key, pick buttons your game doesn't use.

---

## OCR Overlay

Switch to the OCR Overlay with **OCR Overlay** in the menu bar, with **Overlay type** in *Settings → General*, or from
any app with **Overlay switch key/buttons**. The text box hides, and you can point at the text in your game or app
directly. Overlay options are in *Settings → OCR Overlay*, and how text is read (also by **Read text from OCR**) in
*Settings → OCR*. MacPopup needs the **Screen Recording** permission (*System Settings → Privacy & Security*).

### Selecting a Window and Capture Areas

Choose **Select Captured Window…** in the menu bar, click **Select…** next to **Captured window** in *Settings →
General*, or press your **Select captured window key** in any app:

1. **Choose the window**: Click the window you want MacPopup to read, or **Whole Screen**.
2. **Draw capture areas *(optional)***: Drag over the areas where text appears, then click **Done** (`Return`).
   - The **first area** is the **dialogue box**: MacPopup waits for its text to settle, and matches it with WebSocket
     lines.
   - **Other areas** (menus, choices, UI) are read as soon as they change.
   - **Undo** (`Delete`) removes the last area, **Other Window** picks another window, and **Cancel** (`Esc`) keeps your
     previous selection. Switching to another app or Space also takes you back to picking a window.

When you select again, the window you're reading comes to the front first (even from another Space), with its areas
already drawn.

MacPopup remembers the window by its app and title, even after a restart, including Windows apps in Parallels' Coherence
mode. It's only read while you can see it: on screen in the current Space, and not covered by other windows (partly
covered is fine). The captured window is also used for clean `{screenshot}`s on Anki cards, and its app's audio for
sentence audio and **Read text from audio**, even in the Floating Window.

### Reading the Dialogue

In the dialogue area, MacPopup waits for the text to stop changing before taking the line (**Text must stay unchanged
for**, *Settings → OCR*), so text that types out or fades in is read in full, even over an animated background. You
don't have to wait to look words up: text that's still changing, scrolling or moving can be hovered too.

### OCR Engines

Choose the engine in *Settings → OCR → Text recognition engine*. Lines with none of your language's characters
(*Settings → General → Language*) are skipped, such as an English menu in a Japanese game.

| Engine | Languages | Notes |
| --- | --- | --- |
| **Live Text** *(default)* | Your language, plus English | Built into macOS |
| **meikiocr** | Japanese | Built-in models by rtr46, trained on Japanese games. Faster than Live Text, with tighter boxes around each character |
| **PP-OCRv6 Manga** | Japanese, Chinese | Built-in models by Kellenok, fine-tuned from PP-OCRv6 for manga and anime: vertical text in speech bubbles, and sound effects |
| **mida + VOCR6** | Japanese | Built-in models: rtr46's mida finds the lines and vita-vn-ocr's VOCR6 reads them, as in meikipop. Horizontal and vertical game text; faster than meikiocr |
| **Screen AI** | Most scripts | Google Chrome's own OCR engine, run with Core ML. Needs setup (below) |
| **OneOCR** | Most scripts | The OCR engine of the Windows 11 Snipping Tool. Needs setup (below) |

**Setting up Screen AI and OneOCR**:

- **Screen AI**: Make sure Chrome has downloaded its Screen AI component (`~/Library/Application
  Support/Google/Chrome/screen_ai`), run `scripts/convert-screenai.py` to make a `.zip` file, and load it with **Screen
  AI models → Load…**.
- **OneOCR**: Run `scripts/convert-oneocr.py` on your decrypted OneOCR model files (`config.json` and `Model_Edge`) to
  make a `.zip` file, and load it with **OneOCR models → Load…**.

**Cloud recognition (second pass)**: Optionally turn on **Google Lens** or **Bing** (*Settings → OCR*). Local OCR reads
the text first, so popups stay quick; once a dialogue line settles, a picture of the dialogue area is sent to Google
Lens or Bing for a more accurate reading. Lines matched with a WebSocket line keep the WebSocket text.

### WebSocket + OCR Matching

With a text hooker (WebSocket) and the OCR Overlay both running, and **Match and fix OCR with WebSocket text** on, you
get the best of both:

- You point at words on the game screen, where OCR found them, while MacPopup replaces misread characters with the exact
  text of the WebSocket line.
- It works with partial lines (such as sentences split over pages), and with games that show several lines at once
  (**Previous WebSocket lines to match**).
- In Japanese, furigana can be left out (**Ignore furigana**), so the small readings above kanji don't get in the way.

---

## Anki Integration

MacPopup adds cards with your Yomitan profile's deck, note type and fields, and fills in these markers from what you
were reading:

- **Sentence**: `{sentence}`, `{cloze-prefix}`, `{cloze-body}`, `{cloze-suffix}`, `{sentence-furigana}` and
  `{sentence-furigana-plain}`, from the line you looked the word up in.
- **`{screenshot}`**: A clean picture of your **Captured window** (without overlays or windows covering it), or of the
  screen if no window is chosen or it isn't on screen. Taken at 1x, or at the display's Retina scale with **Screenshot
  resolution** set to Full Retina resolution (*Settings → Anki Screenshot*). With a captured window, MacPopup also takes
  a screenshot shortly after each new line and keeps the latest ones (**Screenshots to keep**, 20 by default), so a card
  shows the scene of its line even if the game has moved on. A card added from a nested popup gets a picture of that
  popup instead.
- **Other**: `{document-title}` (the name of the app in front), `{clipboard-text}` and `{clipboard-image}` (what's on
  the clipboard), and `{popup-selection-text}` (the text you selected in the popup).

> [!TIP]
> **Selected popup text in templates**: The Yomitan API can't see text you select in a MacPopup popup. If your card
> templates use it (for example `getMedia "popupSelectionText"`, to pick a dictionary by selecting its name), turn on
> **Use local Handlebars templates** in *Settings → Anki* and import your Yomitan settings, so MacPopup fills in the
> templates itself.

### Automatic Sentence Audio Recording

With *Settings → Anki Audio*, one shortcut after adding a card adds the character's voice line from your game:

1. **From the recorded audio**: MacPopup records the last few minutes of your game's audio in memory (**Record game
   audio for the last**, 5 minutes by default; without a captured window, the audio of every app except MacPopup), along
   with when each line appeared. When you press the shortcut, it finds the line of the last card you added from a popup
   and cuts out its voice right away, using macOS's sound classifier to leave out music and sound effects. If the line
   is still being spoken, it waits for the voice to end.
2. **From the backlog**: If the line isn't in the recorded audio anymore (it's too old, or you moved on before the voice
   finished) and **Visual novel backlog capture** is on, MacPopup replays it instead: it brings your game to the front,
   presses your **Keys to open backlog**, records the voice while it replays, then presses your **Keys to close
   backlog**. With **Automatically detect start and end of speech** on, recording stops when the voice ends, and nothing
   is saved if no voice is heard in time. With it off, press the shortcut again to stop.
3. **Into the card**: The clip goes into the **Sentence audio field** (*Settings → Anki Audio*) of that card, and of any
   other cards you added from the same line, wherever that field is empty. You can have it played back afterwards. Cards
   added from a nested popup don't get sentence audio.

More:

- **Add and record in one go**: Option-click a popup's add button (or use a popup shortcut set to **Add note (sentence
  audio)**). If that overwrites an existing card, the recording replaces its sentence audio, unless **Replace sentence
  audio when overwriting cards** is off (this also applies to audio from IINA).
- If the game is paused (see [Pausing the Game](#pausing-the-game-while-you-read)) while the voice is still playing, the
  audio is added once the game goes on. Windows games in Parallels' Coherence mode are recorded too.
- **Permissions**: MacPopup asks for permission to record other apps' audio when you turn sentence audio on (*System
  Settings → Privacy & Security → Screen & System Audio Recording*). Backlog capture also needs **Accessibility**
  (*Settings → Permissions*).

### Videos in IINA

The [IINA](https://iina.io) plugin in `iina-plugin/` sends the subtitles you're watching to MacPopup, gives cards made
from them the line's own frame and audio, and can transcribe videos without subtitles:

1. **Install the plugin**: Click **Install** in *Settings → IINA Integration* to open the plugin in IINA (or, for
   development, run `iina-plugin link iina-plugin` from IINA's `Contents/MacOS`), turn it on in IINA's *Settings →
   Plugins*, and restart IINA. The plugin asks for access to files, which it needs for live streams and cookies.
2. **Connect it**: Add `ws://localhost:6680` in MacPopup's *Settings → WebSockets* (you can change the port in the
   plugin's settings). Each subtitle arrives like a text hooker's line, so you can read it in the Floating Window, or
   hover the subtitles on the video with the OCR Overlay and **Match and fix OCR with WebSocket text** on.
3. **Clean screenshots and audio**: For these lines, `{screenshot}` is the frame from the middle of the line, without
   subtitles, at the video's size, and the **Sentence audio field** gets the line's audio, padded as set in *Settings →
   IINA Integration*. You can turn either off there (**Use clean screenshots for cards**, **Use clean audio for
   cards**). This also works with network streams, including web videos IINA plays through yt-dlp (MacPopup fetches them
   with IINA's headers, cookies and proxy). For live streams, it takes the line from IINA's cache, which holds about the
   last minute played.
4. **Transcribe videos without subtitles**: Turn on **Transcribe videos without subtitles** (*Settings → IINA
   Integration*). MacPopup transcribes the video ahead of where you're watching, with the model in *Settings →
   Transcription*, and shows it as a subtitle track (**MacPopup transcription**) whose lines work like any other
   subtitles. It stops if you add a subtitle file in your language, and doesn't work with live streams. **Read text from
   audio** pauses meanwhile. Transcriptions are saved, so a video isn't transcribed twice: to delete them, click
   **Clear…** next to **Saved transcriptions**.

---

## Experimental iPhone App

`ios/` has an experimental iPhone app (iOS 18 or later) that reads pictures and the screen with the same OCR engines,
and opens the text in Safari for a dictionary extension such as Yomitan. It's separate from MacPopup: see
[ios/README.md](ios/README.md) for setup and use.

---

## Reporting Problems

If something doesn't work right, turn on **Debug** (*Settings → General*) and use MacPopup until it happens again.
MacPopup then logs what it does (lines and OCR readings, popups, shortcuts, cards, Anki Audio and screenshots, the
controller and game pauses), with your settings (except your AnkiConnect key) and its version.

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

You need Swift 5.9+ (the Xcode Command Line Tools) and Node.js 18+ on an Apple Silicon Mac.

```sh
cd web && npm install && cd ..
scripts/build.sh            # Builds the release app at build/MacPopup.app
scripts/build.sh debug      # Builds a debug version
```

- **First build**: It downloads Yomitan's kanji stroke order font and libcurl-impersonate (for Google Lens and Bing),
  and builds a small ffmpeg (for IINA lines), which takes a few minutes. They're kept in `build/cache`.
- **Code signing**: To keep macOS from asking for the Screen Recording and Accessibility permissions again after each
  build, sign the app with your own certificate: put its name (as `security find-identity -v -p codesigning` lists it,
  e.g. "Apple Development: Your Name (TEAMID)") in a `.signing-identity` file at the top of the repository (it's kept
  out of git), or set `MACPOPUP_SIGN_IDENTITY`. Otherwise the app is signed ad hoc.
- **Notarization**: `scripts/notarize.sh` builds a notarized copy to share, in `build/notarized` (the app and a zip of
  it). It needs a "Developer ID Application" certificate (or `MACPOPUP_NOTARY_IDENTITY`) and a notarytool keychain
  profile (made with `xcrun notarytool store-credentials`), whose name goes in a `.notary-profile` file (kept out of
  git) or `MACPOPUP_NOTARY_PROFILE`.

---

## Support the Project

If you like what I do, you can [Sponsor me here on GitHub](https://github.com/sponsors/AuroraWright)!

---

## License and Acknowledgments

MacPopup is licensed under the **GPL-3.0** (`LICENSE`).

- **Yomitan and OwOtan**: Large parts of the code are derived from [Yomitan](https://github.com/yomidevs/yomitan), with
  extra changes from the [OwOtan](https://github.com/AuroraWright/owotan) fork (see `vendor/yomitan/README.md` and
  `LICENSE`).
- **texthooker-ui**: The text box's line processing, settings and replacements are adapted from
  [texthooker-ui](https://github.com/Renji-XD/texthooker-ui) under the **MIT License** (see
  `vendor/texthooker-ui/README.md` and `vendor/texthooker-ui/LICENSE`).
- **meikiocr**: The Core ML models (`vendor/meikiocr`) are licensed under the **LGPL-3.0**, and
  `Sources/OCREngines/MeikiOCR.swift` is adapted from `meikiocr` under the **Apache License 2.0** (see
  `vendor/meikiocr/README.md`).
- **PP-OCRv6 Manga**: The Core ML models (`vendor/ppocr-manga`) are licensed under the **Apache License 2.0** (see
  `vendor/ppocr-manga/README.md`).
- **mida + VOCR6**: The VOCR6 Core ML models and heads (`vendor/mida-vocr6`) are licensed under the
  **GPL-3.0-or-later**, for **non-commercial use only**, and `Sources/OCREngines/MidaVOCR6.swift` is adapted from
  meikipop's provider and vita-vn-ocr's code under the **GPL-3.0-or-later** (see `vendor/mida-vocr6/README.md`). The
  mida model is by rtr46.
- **Speech recognition models**: They don't come with MacPopup; the `scripts/convert-*.py` scripts download them from
  their authors.
  - **Kitsune**: **CC BY-NC 4.0** (**non-commercial use only**)
  - **SenseVoice**: the FunASR model licence
  - **Parakeet**: **CC BY 4.0**
  - **Whisper**, **anime-whisper** and **SaT**: **MIT License** (Whisper runs with Argmax's
    [WhisperKit](https://github.com/argmaxinc/WhisperKit), **MIT License**)
  - **Live Caption**: Google's language packs, which `scripts/convert-soda.py` downloads from Chrome's update server for
    **your own use only** (don't share them or the `.zip` file). MacPopup runs them itself (`Sources/SODA`), without
    Chrome.
