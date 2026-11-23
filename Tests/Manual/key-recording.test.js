// Settings' recorders with real key presses (synthetic key events don't stand in for a person's here): a person presses
// what a window at the top of the screen asks for, and the driver checks the setting saved each time. Scanning →
// Record New Input (Option, Control and Shift held together), Anki Audio → Recording key (⌃⌥R) and Keys to open
// backlog → Add Key (⌥K), Popup Shortcuts → the first shortcut (⌃⇧J).
// Needs a person at the Mac: the keys go to the test instance's Settings window, in front.
// interactive
// settings: {"scanModifier": "custom", "scanInputs": ["shift"], "sentenceAudioShortcut": null, "sentenceAudioOpenKeys": []}
// driver: python3 -I "$REPO/Tests/Manual/key-recording-driver.py"
// timeout: 420

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
