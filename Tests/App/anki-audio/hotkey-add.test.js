// The popup shortcut "add the card with its line's voice" (addNoteSentenceAudio, the only one set up; pressed as the
// host does on its global shortcut, window.__macpopupHotkey(0), since synthetic key presses don't reach global
// shortcuts) does what an Option-click does: as option-add.test.js (a popup on line 2 once line 3 shows), the card
// (note 444) gets line 2's voice whole. Expected from evals game-tests optadd-hotkey.js (Option-click's result).
// It plays sound: the test window's music and Kyoko's lines, quietly (volume 0.15), for about 35 s.
// While the popup shows, the app registers ⌃⌥⇧F19 as a global shortcut (the popup shortcut's key).
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 0, "hotkeys": [{"action": "addNoteSentenceAudio", "argument": "0", "key": "F19", "modifiers": ["ctrl", "alt", "shift"], "enabled": true}], "ankiRenderTemplatesLocally": true}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/voicegame.swift")" "$RUN" 0.15 8 14 17 24
// driver: python3 -I "$REPO/Tests/App/anki-audio/clip-driver.py" voice0 voice1 voice2 voice3
// timeout: 120

test('overlay', async () => {
	const text = (await runFile('voice2.txt')).trim();
	await windowStep('line 3 shown', 60000);
	const line = await lineWith(text.slice(0, 6), 10000);
	// In view first: with four long lines the box is scrolled, and this one is partly under the header.
	line.scrollIntoView({ block: 'center', behavior: 'instant' });
	await wait(300);
	await native('debugMouse', center(rangeOf(line, text.charAt(1)).getBoundingClientRect()));
	const button = await until('the add button', () => [...(popupDocument()?.querySelectorAll(
		'.note-actions-container .action-button[data-action=save-note][data-card-format-index="0"]') ?? [])].find((b) => !b.disabled), 10000);
	const before = (await sentenceAudioNotes()).length;
	expect(!!button, 'the popup with its add button');
	await wait(500);
	window.__macpopupHotkey(0);
	const added = await until('the card', async () => (await sentenceAudioNotes()).slice(before).find((n) => n.startsWith('card ')), 10000).catch(() => '');
	expect(/^card 444 added, line \d+: its line.s voice asked for$/.test(added), `the card added: "${added}"`);
	const outcome = await until('Anki Audio', async () => (await sentenceAudioNotes()).slice(before).find((n) =>
		/^[\d.]+s, macpopup-sentence-/.test(n)
		|| (/^message: /.test(n) && !/^message: Waiting for speech to finish/.test(n)) // (shown while it waits, not an outcome)
		|| (/^history: /.test(n) && !/^history: (line \d|voice |waiting |no voice in )/.test(n))), 20000).catch(() => '');
	expect(/^[\d.]+s, macpopup-sentence-/.test(outcome), `a clip from the recorded audio: "${outcome}"`);
	await wait(1500);
	const mock = await mockLog();
	expect(mock.some((l) => / updateNoteFields .*"SentenceAudio": "\[sound:macpopup-sentence-/.test(l)), 'the card got the clip');
	log('clip 1 voice2');
});
