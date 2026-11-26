# Tests

Run them with `scripts/test.sh [unit|web|all]` (all: unit and web) or `scripts/test.sh app`. It prints PASS, or FAIL
with what failed, and exits with 1 on a failure.

| Suite | Folder | Runs with | Needs | Time |
|---|---|---|---|---|
| unit | `Unit/` | `swift test` (Swift Testing) | nothing | ~45 s with the first debug build, then seconds |
| web | `web/` | `node --test Tests/web/` | Node | under a second |
| app | `App/` | `scripts/test.sh app [--no-build] [--interactive] [--network] [test or folder...]` | a Mac session; the user's MacPopup and IINA closed | about 10 s a test, plus the build |
| manual | `Manual/` | `Tests/App/run.sh --interactive Tests/Manual/<name>.test.js` | a person (and for some, a controller or Parallels), or the network | minutes each |

## Unit (`Unit/`)

Plain logic in the Swift targets, one file per area. The test target imports the app and its modules with
`@testable import`, so internal types are reachable. Logic that sits in a SwiftUI view is moved out into a plain type
first (as `EditedLines` was out of Settings' `LinesEditor`), and private functions a test needs are made internal (as
`VideoTranscriber.isLanguage` and OneOCR's `mlasSumExp`). Pictures are drawn in the test (`OCRLayoutTests`,
`OCRFuriganaTests`), not taken from games.

Not a suite: `python3 -I scripts/check-settings.py` checks that every setting in `web/src/lib/settings-defaults.js` is
read somewhere in `web/src` or `Sources`, and that every key read from the settings or shown in Settings is defined
there (PASS, or what's wrong and exit 1). Neither `scripts/test.sh` nor the build runs it.

## Web (`web/`)

The web code's modules (`web/src/lib`) that load without a page: most of them, except the ones importing Yomitan's
background code or Handlebars. Tests use `node:test` and `node:assert/strict`, with no packages to install.

## App (`App/`)

Each test is a page script run in a test instance of the app: a development build at `build/test/MacPopup.app`
(`scripts/test.sh app` builds it with `MACPOPUP_APP`; the app as shipped ignores the test settings and isn't run).
`harness/launch.sh` starts the instance with its own settings (the defaults, then `harness/base-settings.json`, then the
test's), pasteboard and folders, against `harness/mock.py` (AnkiConnect, the Yomitan API with 150 entries for any lookup,
and an audio server), and only when the user's MacPopup and IINA aren't running (checked again just before the launch,
and while the test runs: the user's MacPopup starting, or IINA in a test that doesn't start IINA itself, stops the test
and fails it). The user's settings are exported before each test and compared after: a change fails it. Its `// beside:`
and `// driver:` commands run in process groups of their own, stopped with everything they started; a driver stopped
after the timeout fails the test. Ctrl-C (or a kill) stops the test instance and all of that too, still comparing the
settings, and no tests are run after it. Tests run one at a time; each one's logs are in
`build/test/runs/<time>/<test>/` (`app.log`, `test.log`, `mock.log`, `debug.jsonl`), which can be deleted any time.
launch.sh exits with 0 (PASS), 1 (FAIL, also when the `// setup:` failed), 2 when no test can run now (the user's app
running, not a development build: run.sh stops) or 3 when only this one couldn't (run.sh goes on, and counts it).

A test file (`<area>/<name>.test.js`) starts with a comment saying what it checks, then header lines:

```js
// Dictionary images in the popup: ...
// mock: MOCK_IMAGES=1                       mock.py's switches
// clipboard: 明日も晴れるといいね              put on the instance's pasteboard once the test is ready
// settings: {"clipboardMonitor": true}       settings over the defaults
// timeout: 60                                seconds until the test counts as stuck
// interactive                                moves the real pointer, types or makes sound: only with --interactive
// network                                    sends something to a service on the internet: only with --network too

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	equal(line.textContent, '明日も晴れるといいね', 'the line');
});
```

`test(page, body)` runs `body` in that page (`overlay`, `settings`, …). `harness/test-lib.js` has the checks (`expect`,
`equal`, `near`, each logged as `TEST ok …` or `TEST FAIL …`) and helpers: `until`, `wait`, `lineWith`, `rangeOf`,
`center`, `popupDocument`, `popupVisible`, `boxText` (the highlight boxes' text), `gamepadPress`, `mockLog`, `runFile`
and `debugRecords` (the run folder's files, with `MOCK_RUN_FILES=1`), `windowSteps` and `windowStep` (a test window's
steps, from beside.log), `watch` (a value's changes over time), `ocrText`, and `native` for the app's bridge, e.g.
`native('debugMouse', {x, y})` to point at something without moving the real pointer, or `native('debugGameInput')`
for a click or key press that went to the game (see OCRController.gameInput). A test passes when it finished,
checked something and nothing failed.

More header lines, for what a page script can't do (see `harness/launch.sh`):

- `// setup: <command>` runs before the launch (stopped and failed after 120 s), e.g.
  `"$HARNESS/tools/say.sh" -v Kyoko -o "$RUN/voice.aiff" …` for a sound file (`say`, tried again when it hangs, as it
  sometimes does);
- `// env: NAME=value` passes test variables to the app (`$RUN` is the run folder);
- `// beside: <command>` runs from just before the launch until the test ends, e.g. a test window for OCR mode to read
  (`ocr-windows/windows/*.swift`, compiled by `"$HARNESS/tools/build.sh" <path>.swift`, which prints its path);
- `// driver: <command>` runs beside the instance, with `RUN`, `HARNESS`, `REPO`, `SUITE` and `PID` set, and prints
  `TEST ok …`/`TEST FAIL …` lines too. Drivers in Python import `harness/tools/driver.py` (checks, settings, Settings'
  sections and controls over Accessibility with `tools/ax.swift`, window-only screenshots); Swift tools are compiled
  into `build/test/tools` by `tools/build.sh` when needed. Settings is SwiftUI, so its tests are drivers.

With `"gamePause": true` in a test's settings, launch.sh first makes a window of its own (`tools/frontguard.swift`) the
frontmost app, and doesn't run the test if it can't: Game Pause freezes the frontmost app when the OCR window isn't
found, which would otherwise be the terminal running the tests (test instances don't fall back to the frontmost app;
the guard is there in case that changes).

`harness/mock.py`'s switches (`// mock:`): `MOCK_IMAGES` (dictionary images), `MOCK_NOTES` (notes 111 and 222 exist),
`MOCK_EDITOR=browser|closed` (Anki's card browser), `MOCK_ADD_NOTE=<id>`, `MOCK_GONE_FORMAT` (with `MOCK_NOTES`
or `MOCK_EDITOR`: a second card format, for a note type Anki doesn't have), `MOCK_PROFILE`, `MOCK_PROFILE_FAIL=<n>` and `MOCK_PROFILE_FAIL_FOR=<seconds>`
(Yomitan's display options), `MOCK_TOKENIZE` (furigana), `MOCK_MATCH_LENGTH=<n>`, `MOCK_SHORT_ENTRY` (the second entry matches 晴 alone), `MOCK_WEBSOCKET` (a WebSocket server
on 59880 sending what's POSTed to 59881), `MOCK_WEBSOCKET_PORTS=<port>,…` (servers that stay connected),
`MOCK_RUN_FILES`, `MOCK_SHOT` (with `MOCK_EDITOR`: a {screenshot} field), `MOCK_OVER` (with `MOCK_EDITOR`: note 333
already has sentence audio). Card formats come with their fields' keys sorted, as Chrome's native messaging sends them.

| Folder | What |
|---|---|
| `popup/` | the dictionary popup: images, audio and its menu, notes, Anki's editor, tooltips, Yomitan's display settings, collapsible definitions, scanning inside it |
| `overlay/` | the text box: highlight boxes after a resize, gone from the screen after the popup closes (window screenshots; `highlight-clear-driver.py` needs Python's PIL) and with the real pointer (a wrapped row, a scrolling box, furigana), fonts and effects, the debug log, sentence audio shortcut, switching the overlay, the box never narrower than its buttons and long messages wrapping inside it |
| `ocr/` | OCR mode's text while a popup is open, a hover while the text changes looked up once it's current, the crash guard, the language filter |
| `ocr-windows/` | OCR mode (Live Text) on test windows (`windows/`, shown without taking focus, at or past the main screen's right edge): typed, sparse, fading, animated, covered, untitled and floating (kept on top) windows, blinking icons (also one read as a bracket or as a letter right after the text), moving text, a visual novel's page in the text box (also with text replacements), a card's sentence with text replacements, kept screenshots, the captured window's screenshot sizes and popups closing when the page is told it hides or the space changed (the page's handlers, called by the test; Live Text pinned); and the debug log, stale debug glyphs and noted lines |
| `gamepad/` | the controller in the text box and on OCR text, and switching to another app while it has focus |
| `settings/` | Settings over Accessibility: each section rendering (window-only screenshots, the same a second later), labels and hints staying put when a control changes width, scanning inputs, Yomitan's display settings, the WebSocket limit and connections following the saved URLs, clearing IINA's saved transcriptions (made-up ones in the run folder), the Font row and the macOS Fonts panel (`font-panel*`: the panel's level, focus, size field, effects switch and menus, the row's text and colors, Clear, the panel staying open while the row scrolls away and closing with the section or Settings; the panel's typeface and style lists and color wells aren't driven, and the frame the panel saves in the user's com.aury.macpopup is put back); typing into the WebSocket URL box and resizing the window with real keys and pointer (`sections-driver.py` and `font-panel-driver.py` need Python's PIL) |
| `picker/` | the window picker: bringing the OCR window to the front, Escape, another app coming to the front |
| `game-pause/` | Game Pause's pause and scan shortcut on a typed line, its end when another app comes to the front, and the pause helper refusing another program (`pause-client.swift`, signed ad hoc; not interactive) (they stop the test window's process with the pause helper: `harness/tools/gamestate.py` logs its state). The test build has no helper of its own and asks the one the installed MacPopup registered: a copy that has it, launched from elsewhere, takes over the helper's registration and launchd can't start it anymore (exit 78) until it's reset |
| `anki-audio/` | Anki Audio with a game that speaks (`windows/`, voices made with `say -o` by `voices.sh` at test time): voices cut from the recorded audio (WebSocket and OCR lines), Option-click, shortcut and overwrite adds, two cards in one pause, recording the captured app (warm, cold, a web view) and no voice, and the recorded audio's tap not freezing the app; `clip-driver.py` checks the clips (`corr.swift`) and screenshots (`readtext.swift`) |
| `profile/` | the app's memory (footprint) and CPU while idle and over 48 lookups, against ceilings about 1.5x what was measured (`profile-driver.py`, samples in the run folder's `samples.jsonl`) |
| `transcribe/` | "Read text from audio" (Live Caption) on a sound file the app reads in place of an app's audio (`MACPOPUP_TEST_TRANSCRIPTION_FILE`, nothing played): Kyoko's sentences made with `say -o` at test time by `speech.py` (music by `make-music.py`, both needing numpy installed for `python3 -I`, which leaves out the user's site-packages), which also clones Live Caption's models (and SaT) from the user's and fails the test without them. Lines over music, words as they're heard, the box paused and the listener restarted meanwhile, WebSocket lines between lines that grow ("Detect sentence ends") |
| `welcome/` | the first launch's window |
| `yomitan-api/` | lines dropped before their tokenize reaches Yomitan |
| `iina/` | the IINA plugin in the user's IINA (`iina.py`; all interactive): its plugin must be the repo's, on 6680; history and recent files are off for the run, and its settings and plugins are checked unchanged (copies of the settings and the plugins' preferences from before are in the run folder); only the IINA the test started (iina-cli and the IINA it started) is ever quit; transcripts go to `/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts`, the tests' own (the user's are in their `~/Library/Caches`), whose files are deleted after unless a part of that path leads elsewhere. Its lines and statuses, cards' sentence audio and screenshots from a file and from streams (HTTP, HLS, split, DASH, live, proxy, cookie), dumps from IINA's cache, transcripts of videos without subtitles, and Settings' Clear of saved transcriptions while one is being made (`transcribe-clear`) |

Tests with `// interactive` (e.g. `popup/image-open`, which opens Preview) only run with `--interactive`; a line under
the description says what each does to the Mac. Pages move the real pointer with `pointerMove(from, to, ms)` and
`pointerClick(at)` (page points; `// driver: python3 -I "$HARNESS/tools/pointer.py"`, with `MOCK_RUN_FILES=1`), and wait
for a driver's log line with `driverSaid(prefix)`. Drivers use `driver.py`'s `mouse` (`tools/mouse.swift`: moves,
clicks and drags only where a window of the test instance is in front, without modifiers), `keep_pointer` (puts the
pointer back when the driver ends), `keys` (`tools/keys.swift`: one key press, only while one of the given processes is
the frontmost app and none of its menus is open), `activate` (System Events brings a test window's app to the front),
`frontmost`, `logged` (a page's `TEST` line) and `beside_log`; `tools/wins.swift` lists the on-screen windows,
`ax … frame` a control's frame and `ax … frames` a window's texts with theirs. Test windows that come to the front: `picker/plainwin.swift`. Left manual: the
controller's cursor box and the popup's highlight while someone scrolls with a trackpad (`Manual/scroll-boxes.test.js`,
`Manual/popup-scroll.test.js`, which record the test window: a page can't see the text lag behind the boxes in
WebKit's scrolling).

## Manual (`Manual/`)

What needs a person or hardware, with when and how to check it and the tools for it: see `Manual/README.md`.

## Helpers (`Helpers/`)

`yomitan-api-host.py` checks the Yomitan API's native messaging host on its own, with a fake browser and Yomitan (about
45 s); `scripts/test.sh app` runs it after the app tests when none are named.

## Writing a test

- Put it in the lowest suite that can catch the bug: unit or web before anything that launches the app.
- Name it after the behavior (`returnOnTheFifthLineIsRefused`), and check the result: no tests that only print.
- Keep fixtures small and in the test file, or next to it in a `Fixtures/` folder. Screenshots, recordings and audio
  from games or videos stay out of the repo (`test-corpus/`, local).
- Check a new test fails without the fix before relying on it.
