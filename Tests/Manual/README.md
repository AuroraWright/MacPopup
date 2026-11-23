# Manual checks

What needs a person or hardware at the Mac. Each check says when to do it, how, and what to expect. The two with a
test file run on a test instance like the app tests, one at a time, with the user's MacPopup and IINA closed:
`Tests/App/run.sh --interactive Tests/Manual/<name>.test.js` (a plain `Tests/App/run.sh` never runs them). A window at
the top of the screen (`tools/prompt.swift`, which doesn't take the keyboard) says what to do; their drivers share
`manual.py`.

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

## A real controller

When: after changing Settings → Controllers, the controller's learning (GamepadLearning) or how controllers are opened.
The learning's logic is in the unit tests (on synthetic timelines); this is the part with hardware.

1. Connect a controller (a DualShock 4/DualSense, a Switch Pro Controller or Joy-Con, an Xbox controller, an 8BitDo).
   Settings → Controllers → Set Up, and follow the steps: each control is asked for once and shown as learned.
2. With a scan button set (Scanning → Controller scan key), the button gives the text box focus: the D-pad and both
   sticks move the cursor a character at a time, and the popup opens on the word at the cursor once it rests.
3. With a game in front, the game doesn't react to the controller while MacPopup uses it, and does again after.

Tools (`swiftc -O -o <name> <name>.swift`): `gc-list` (what GameController sees: profiles, buttons, axes),
`gc-probe` (GameController's changes for 5 minutes), `hid-peek` (a Nintendo controller's raw report IDs, without
seizing it), `report-log` (a controller's raw reports, opened shared, the bytes that changed marked; `CONTROLLER=<part
of its name>`, `SECONDS=`), `dump-reports.py <recording.json> <from> <to> [bytes]` (a gamepad recording's reports
between two times). Recordings the app saves (MACPOPUP_DEBUG_GAMEPAD) stay local: they're the user's controllers.

`dualsense-dump/` is for people with a DualSense to send a recording (its `README.txt` is written for them): it records
the raw reports and GameController's view while it guides them through each control.

## Game Pause with a game in Parallels

When: after changing Game Pause's process choice or the pause helper. Ask before running: it uses the user's VM.

With a Windows game in a Parallels Coherence window as the OCR window and Game Pause on, the pause shortcut stops the
VM's processes (the game stops; Parallels' window stays responsive enough to draw) and the second press resumes it;
nothing else is stopped. The VM's state can be watched with `prlctl list -a`.

## Cloud OCR after a window moves

When: after changing how cloud readings are reused. Needs the network and a cloud engine: ask first.

In OCR Mode with a cloud engine, once a line is complete and read, move the game's window: the line is read again by
the cloud engine, not taken from the reading before the move.
