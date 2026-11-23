// Game Pause with two cards Option-added from one popup: the game (windows/voicegame.swift) shows line 0 at 8 s (its
// voice 4.1 s long); a second after the voice ended (before Anki Audio's 3 s of silence that end a voice), a popup on
// it (debugMouse) pauses the game, and its first two entries' add buttons are Option-clicked 1.5 s apart; 4 s later the
// popup is closed. The game stays stopped all the time the popup is open after the first add (its process state, from
// harness/tools/gamestate.py), and both cards get line 0's voice, whole, once it goes on (after the popup closed).
// Expected from evals game-tests README (pause-multi, 2026-11-15: the game running in 0 of 34 checks after the
// fix, both cards getting the voice once it goes on). Without the pause helper it fails first with "NOT RUN: …".
// It pauses the test window's process (voicegame, with the pause helper) and plays sound: its music and a line,
// quietly (volume 0.15), for about 30 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444
// env: MACPOPUP_DEBUG_OCR=1
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "gamePause": true, "gamePauseShortcut": null, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 3000, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 0, "ankiRenderTemplatesLocally": true}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/voicegame.swift")" "$RUN" 0.15 8 40
// driver: python3 -I "$HARNESS/tools/gamestate.py" "$REPO/build/test/tools/voicegame" & python3 -I "$REPO/Tests/App/anki-audio/clip-driver.py" voice0 voice1 voice2 voice3; wait
// timeout: 120

/** The popup's add buttons (the first card format's), one an entry. */
function addButtons() {
	return [...(popupDocument()?.querySelectorAll('.note-actions-container .action-button[data-action=save-note][data-card-format-index="0"]') ?? [])];
}

function optionClick(button) {
	button.dispatchEvent(new (button.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true, altKey: true }));
}

test('overlay', async () => {
	const text = (await runFile('voice0.txt')).trim();
	const shown = await windowStep('line 0 shown', 60000);
	const line = await lineWith(text.slice(0, 6), 10000);
	await until('a second after the voice ended', () => Date.now() >= shown + 5100, 10000);
	const notesBefore = (await gamePauseNotes()).length;
	// In view first: with four long lines the box is scrolled, and this one is partly under the header.
	line.scrollIntoView({ block: 'center', behavior: 'instant' });
	await wait(300);
	await native('debugMouse', center(rangeOf(line, text.charAt(1)).getBoundingClientRect()));
	await until('the popup', () => popupVisible() && addButtons().filter((b) => !b.disabled).length >= 2, 10000).catch(() => {});
	const note = await until('Game Pause\'s note', async () => (await gamePauseNotes())[notesBefore], 5000).catch(() => '');
	if (!note?.startsWith('game paused')) {
		expect(false, `NOT RUN: the game wasn't paused, so nothing else is checked: ${note || 'no note from Game Pause'}` +
			' (the pause helper needs allowing in Settings → Permissions → Pause Helper, and launchd must start it)');
		return;
	}
	log(`Game Pause: ${note}`);
	expect(addButtons().length >= 2, `a popup with two entries' add buttons: ${addButtons().length}`);
	const before = (await sentenceAudioNotes()).length;
	const added = Date.now();
	optionClick(addButtons()[0]);
	await wait(1500);
	optionClick(addButtons()[1]);
	await wait(4000);
	equal(popupVisible(), true, 'the popup still open 4 s after the second add');
	const closing = Date.now();
	window.__macpopupReleaseForGame();
	await wait(300);
	equal(popupVisible(), false, 'the popup open once closed');
	await wait(9000);

	const states = (await processStates()).filter((s) => s.time >= added && s.time <= closing - 300);
	const running = states.filter((s) => !s.state.startsWith('T'));
	expect(states.length > 30 && running.length === 0,
		`the game stopped while the popup was open after adding: running in ${running.length} of ${states.length} checks`);
	const after = (await processStates()).filter((s) => s.time >= closing + 1500);
	expect(after.length > 0 && !after[0].state.startsWith('T'), `the game going on after the popup closed: ${after[0]?.state}`);
	const notes = (await sentenceAudioNotes()).slice(before);
	log(`Anki Audio: ${JSON.stringify(notes)}`);
	equal(notes.filter((n) => /^card 444 added, line \d+: its line.s voice asked for$/.test(n)).length, 2, 'cards added asking for the voice');
	const clips = notes.filter((n) => /^[\d.]+s, macpopup-sentence-/.test(n));
	equal(clips.length, 2, 'clips from the kept audio');
	const given = (await mockLog()).filter((l) => / updateNoteFields .*"SentenceAudio": "\[sound:macpopup-sentence-/.test(l))
		.map((l) => Number(l.split(' ')[1]));
	expect(given.length === 2 && given.every((t) => t > closing),
		`both cards given the voice after the popup closed: ${given.map((t) => `${((t - closing) / 1000).toFixed(2)} s`).join(', ')}`);
	log('clip 1 voice0');
	log('clip 2 voice0');
});
