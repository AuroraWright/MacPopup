# Tests

Run them with `scripts/test.sh [unit|web|all]` (all: unit and web) or `scripts/test.sh app`. It prints PASS, or FAIL
with what failed, and exits with 1 on a failure.

| Suite | Folder | Runs with | Needs | Time |
|---|---|---|---|---|
| unit | `Unit/` | `swift test` (Swift Testing) | nothing | ~45 s with the first debug build, then seconds |
| web | `web/` | `node --test Tests/web/` | Node | under a second |
| app | `App/` | `scripts/test.sh app [--no-build] [--interactive] [test or folder...]` | a Mac session; the user's MacPopup and IINA closed | about 10 s a test, plus the build |

## Unit (`Unit/`)

Plain logic in the Swift targets, one file per area. The test target imports the app and its modules with
`@testable import`, so internal types are reachable. Logic that sits in a SwiftUI view is moved out into a plain type
first (as `EditedLines` was out of Settings' `LinesEditor`).

## Web (`web/`)

The web code's modules (`web/src/lib`) that load without a page: most of them, except the ones importing Yomitan's
background code or Handlebars. Tests use `node:test` and `node:assert/strict`, with no packages to install.

## App (`App/`)

Each test is a page script run in a test instance of the app: a development build at `build/test/MacPopup.app`
(`scripts/test.sh app` builds it with `MACPOPUP_APP`; the app as shipped ignores the test settings and isn't run).
`harness/launch.sh` starts the instance with its own settings (the defaults, then `harness/base-settings.json`, then the
test's), pasteboard and folders, against `harness/mock.py` (AnkiConnect, the Yomitan API with 150 entries for any lookup,
and an audio server), and only when the user's MacPopup and IINA aren't running. The user's settings are exported before
each test and compared after: a change fails it. Tests run one at a time; their logs are in `build/test/runs/<time>/`
(`app.log`, `test.log`, `mock.log`, `debug.jsonl`), which can be deleted any time.

A test file (`<area>/<name>.test.js`) starts with a comment saying what it checks, then header lines:

```js
// Dictionary images in the popup: ...
// mock: MOCK_IMAGES=1                       mock.py's switches
// clipboard: 明日も晴れるといいね              put on the instance's pasteboard once the test is ready
// settings: {"clipboardMonitor": true}       settings over the defaults
// timeout: 60                                seconds until the test counts as stuck
// interactive                                moves the real pointer, types or makes sound: only with --interactive

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
`native('debugMouse', {x, y})` to point at something without moving the real pointer. A test passes when it finished,
checked something and nothing failed.

More header lines, for what a page script can't do (see `harness/launch.sh`):

- `// setup: <command>` runs before the launch, e.g. `say -v Kyoko -o "$RUN/voice.aiff" …` for a sound file;
- `// env: NAME=value` passes test variables to the app (`$RUN` is the run folder);
- `// beside: <command>` runs from just before the launch until the test ends, e.g. a test window for OCR mode to read
  (`ocr-windows/windows/*.swift`, compiled by `"$HARNESS/tools/build.sh" <path>.swift`, which prints its path);
- `// driver: <command>` runs beside the instance, with `RUN`, `HARNESS`, `REPO`, `SUITE` and `PID` set, and prints
  `TEST ok …`/`TEST FAIL …` lines too. Drivers in Python import `harness/tools/driver.py` (checks, settings, Settings'
  sections and controls over Accessibility with `tools/ax.swift`, window-only screenshots); Swift tools are compiled
  into `build/test/tools` by `tools/build.sh` when needed. Settings is SwiftUI, so its tests are drivers.

With `"gamePause": true` in a test's settings, launch.sh first makes a window of its own (`tools/frontguard.swift`) the
frontmost app, and doesn't run the test if it can't: Game Pause freezes the frontmost app when the OCR window isn't
found, which would otherwise be the terminal running the tests.

`harness/mock.py`'s switches (`// mock:`): `MOCK_IMAGES` (dictionary images), `MOCK_NOTES` (notes 111 and 222 exist),
`MOCK_EDITOR=browser|closed` (Anki's card browser), `MOCK_ADD_NOTE=<id>`, `MOCK_PROFILE` and `MOCK_PROFILE_FAIL=<n>`
(Yomitan's display options), `MOCK_TOKENIZE` (furigana), `MOCK_MATCH_LENGTH=<n>`, `MOCK_WEBSOCKET` (a WebSocket server
on 59880 sending what's POSTed to 59881), `MOCK_WEBSOCKET_PORTS=<port>,…` (servers that stay connected),
`MOCK_RUN_FILES`, `MOCK_SHOT` (with `MOCK_EDITOR`: a {screenshot} field), `MOCK_OVER` (with `MOCK_EDITOR`: note 333
already has sentence audio).

| Folder | What |
|---|---|
| `popup/` | the dictionary popup: images, audio and its menu, notes, Anki's editor, tooltips, Yomitan's display settings, collapsible definitions, scanning inside it |
| `overlay/` | the text box: highlight boxes after a resize and with the real pointer (a wrapped row, a scrolling box, furigana), fonts and effects, the debug log, sentence audio shortcut, switching the overlay |
| `ocr/` | OCR mode's text while a popup is open, the crash guard, the language filter |
| `ocr-windows/` | OCR mode (Live Text) on test windows (`windows/`, shown without taking focus, at or past the main screen's right edge): typed, sparse, fading, animated, covered and untitled windows, blinking icons, moving text, a visual novel's page in the text box, kept screenshots; and the debug log, stale debug glyphs and noted lines |
| `gamepad/` | the controller in the text box and on OCR text, and switching to another app while it has focus |
| `settings/` | Settings over Accessibility: scanning inputs, Yomitan's display settings, the WebSocket limit; typing into the WebSocket URL box and resizing the window with real keys and pointer |
| `picker/` | the window picker: bringing the OCR window to the front, Escape, another app coming to the front |
| `game-pause/` | Game Pause's pause and scan shortcut on a typed line, and its end when another app comes to the front (they stop the test window's process with the pause helper: `harness/tools/gamestate.py` logs its state) |
| `anki-audio/` | Anki Audio with a game that speaks (`windows/`, voices made with `say -o` by `voices.sh` at test time): voices cut from the kept audio (WebSocket and OCR lines), Option-click, shortcut and overwrite adds, two cards in one pause, recording the captured app (warm, cold, a web view) and no voice, and the kept audio's tap not freezing the app; `clip-driver.py` checks the clips (`corr.swift`) and screenshots (`readtext.swift`) |
| `welcome/` | the first launch's window |
| `yomitan-api/` | lines dropped before their tokenize reaches Yomitan |
| `iina/` | the IINA plugin in the user's IINA (`iina.py`; all interactive): its plugin must be the repo's, on 6680; history and recent files are off for the run, and its settings and plugins are checked unchanged; transcripts go to `/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts`. Its lines and statuses, cards' sentence audio and screenshots from a file and from streams (HTTP, HLS, split, DASH, live, proxy, cookie), dumps from IINA's cache, transcripts of videos without subtitles |

Tests with `// interactive` (e.g. `popup/image-open`, which opens Preview) only run with `--interactive`; a line under
the description says what each does to the Mac. Pages move the real pointer with `pointerMove(from, to, ms)` and
`pointerClick(at)` (page points; `// driver: python3 -I "$HARNESS/tools/pointer.py"`, with `MOCK_RUN_FILES=1`), and wait
for a driver's log line with `driverSaid(prefix)`. Drivers use `driver.py`'s `mouse` (`tools/mouse.swift`: moves,
clicks and drags only where a window of the test instance is in front, without modifiers), `keep_pointer` (puts the
pointer back when the driver ends), `keys` (`tools/keys.swift`: one key press, only while one of the given processes is
the frontmost app and none of its menus is open), `activate` (System Events brings a test window's app to the front),
`frontmost`, `logged` (a page's `TEST` line) and `beside_log`; `tools/wins.swift` lists the on-screen windows and
`ax … frame` a control's frame. Test windows that come to the front: `picker/plainwin.swift`. Left manual: the
controller's cursor box while someone scrolls the text box with a trackpad (scratch-tools/popup-timing/scroll-rec.sh,
which records frames of the test window: a page can't see the text lag behind the boxes in WebKit's scrolling).

## Helpers (`Helpers/`)

`yomitan-api-host.py` checks the Yomitan API's native messaging host on its own, with a fake browser and Yomitan (about
45 s); `scripts/test.sh app` runs it after the app tests.

## Writing a test

- Put it in the lowest suite that can catch the bug: unit or web before anything that launches the app.
- Name it after the behavior (`returnOnTheFifthLineIsRefused`), and check the result: no tests that only print.
- Keep fixtures small and in the test file, or next to it in a `Fixtures/` folder. Screenshots, recordings and audio
  from games or videos stay out of the repo (`test-corpus/`, local).
- Check a new test fails without the fix before relying on it.
