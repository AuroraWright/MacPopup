# Manual checks

What needs a person, hardware, or the network at the Mac. Each check says when to do it, how, and what to expect. Each
is a test run on a test instance like the app tests, one at a time, with the user's MacPopup and IINA closed:
`Tests/App/run.sh --interactive Tests/Manual/<name>.test.js` (a plain `Tests/App/run.sh` never runs them). A window at
the top of the screen (`tools/prompt.swift`, which doesn't take the keyboard or become the active app) says what to do;
their drivers share `manual.py`. Helper programs that run beside the test instance must never become the active app:
MacPopup takes that as a switch to another app and lets the controller go (use `.prohibited`, not `.accessory`).

## Settings' key recorders: `key-recording.test.js`

When: after changing Settings' recorders or how keys are read. Synthetic key events don't reach them as a person's do.

Press what the window asks for, while the test instance's Settings window is in front: Option, Control and Shift held
together (Scanning → Record New Input), ⌃⌥R (Anki Audio → Recording key), ⌥K (Anki Audio → Add Key), ⌃⇧J (Popup
Shortcuts → the first shortcut). The driver checks each saved setting; about a minute.

## Highlight boxes while scrolling: `scroll-boxes.test.js`

When: after changing the text box's scrolling or how its highlight boxes are placed.

Scroll the text box near the bottom of the screen up and down with two fingers when asked, for about 15 s. The driver
records the test instance's window alone (`tools/rec-window.swift`, never a screen region) into `scroll.mov` in the run
folder. Look through it frame by frame (QuickTime: the arrow keys): the controller's cursor box stays on the same glyph
in every frame, fast scrolls too. A page can't check this: WebKit scrolls the text on its own thread, so the boxes'
place in the page is right even when the screen shows them a frame or more off.

## The popup's highlight while scrolling: `popup-scroll.test.js`

When: after changing the popup's scrolling or how its highlight boxes are placed.

The page opens the popup on a word (a Shift hover: Shift is the scan key in this run, so the real pointer looks nothing
up on its way to the popup) and looks up a word in the middle of its 150 entries. Put the pointer over the popup and
scroll its entries up and down with two fingers when asked, for about 15 s. The same driver as scroll-boxes records the
overlay window into `scroll.mov`: the popup's highlight box stays on its word in every frame. The page checks it's
still on the word after the scrolling.

## A real controller: `controller.test.js`

When: after changing Settings → Controllers, the controller's learning (GamepadLearning) or how controllers are opened.
The learning's logic is in the unit tests (on synthetic timelines); this is the part with hardware.

1. Connect a controller (a DualShock 4/DualSense, a Switch Pro Controller or Joy-Con, an Xbox controller, an 8BitDo).
   Settings → Controllers → Set Up, and follow the steps: each control is asked for once and shown as learned.
2. With a scan button set (Scanning → Controller scan key), the button gives the text box focus: the D-pad and both
   sticks move the cursor a character at a time, and the popup opens on the word at the cursor once it rests.
3. With a game in front, the game doesn't react to the controller while MacPopup uses it, and does again after.

The test walks through all three (about 5 minutes): the driver presses Set Up… and the scan key's Record Buttons, the
page checks the cursor's moves and the popup, and `tools/gc-watch.swift` watches GameController from the background as
a game would (nothing while the text box has focus, the presses after).

Tools (`swiftc -O -o <name> <name>.swift`): `gc-list` (what GameController sees: profiles, buttons, axes),
`gc-probe` (GameController's changes for 5 minutes), `hid-peek` (a Nintendo controller's raw report IDs, without
seizing it), `report-log` (a controller's raw reports, opened shared, the bytes that changed marked; `CONTROLLER=<part
of its name>`, `SECONDS=`), `dump-reports.py <recording.json> <from> <to> [bytes]` (a gamepad recording's reports
between two times). Recordings the app saves (MACPOPUP_DEBUG_GAMEPAD) stay local: they're the user's controllers.

`dualsense-dump/` is for people with a DualSense to send a recording (its `README.txt` is written for them): it records
the raw reports and GameController's view while it guides them through each control.

## Game Pause with a game in Parallels: `parallels-pause.test.js`

When: after changing Game Pause's process choice or the pause helper. Ask before running: it uses the user's VM.

With a Windows game in a Parallels Coherence window as the OCR window and Game Pause on, the pause shortcut stops the
VM's processes (the game stops; Parallels' window stays responsive enough to draw) and the second press resumes it;
nothing else is stopped. The VM's state can be watched with `prlctl list -a`.

The test finds the Coherence window (`tools/winapps.swift`), saves it as the OCR window with OCR Mode off (so it's never
captured), pauses for 8 s and checks every process's state with ps.

## Cloud OCR after a window moves: `cloud-ocr-moved.test.js`

When: after changing how cloud readings are reused. Needs the network and a cloud engine: ask first.

In OCR Mode with a cloud engine, once a line is complete and read, move the game's window: the line is read again by
the cloud engine, not taken from the reading before the move.

The test does it with a window of its own (`tools/mover.swift`, one line, moved 150 points) and Google Lens: no person
needed, but it sends that window's picture to Google.
