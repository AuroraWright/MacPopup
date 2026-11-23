// Option-clicking a popup's add button gives the new card its line's voice from Anki Audio's kept game audio, and its
// screenshot is the one kept for that line: the game (windows/voicegame.swift) shows and speaks lines at 8, 14, 17 and
// 24 s over WebSocket; once line 3 shows, a popup on line 2 in the text box (debugMouse, not the real pointer) has its
// first add button clicked with Option (a click event with altKey, as a real Option-click makes). The card (note 444,
// MOCK_ADD_NOTE) gets line 2's voice whole (clip-driver.py, corr.swift) and a screenshot showing line 2, not line 3
// (MOCK_SHOT's {screenshot} field, screenshotHistory 20; read with Vision). Expected from evals game-tests
// verify-audio.sh (Option-click add on line 2: the line's voice, whole) and the 2026-11-14 screenshot buffer test ("card
// for line 2 shows line 2").
// It plays sound: the test window's music and Kyoko's lines, quietly (volume 0.15), for about 35 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444 MOCK_SHOT=1
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 20, "ankiRenderTemplatesLocally": true}
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
	button.dispatchEvent(new (button.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true, altKey: true }));
	const added = await until('the card', async () => (await sentenceAudioNotes()).slice(before).find((n) => n.startsWith('card ')), 10000).catch(() => '');
	expect(/^card 444 added, line \d+: its line.s voice asked for$/.test(added), `the card added: "${added}"`);
	const outcome = await until('Anki Audio', async () => (await sentenceAudioNotes()).slice(before).find((n) =>
		/^[\d.]+s, macpopup-sentence-/.test(n)
		|| (/^message: /.test(n) && !/^message: Waiting for the voice/.test(n)) // (shown while it waits, not an outcome)
		|| (/^history: /.test(n) && !/^history: (line \d|voice |waiting |no voice in )/.test(n))), 20000).catch(() => '');
	expect(/^[\d.]+s, macpopup-sentence-/.test(outcome), `a clip from the kept audio: "${outcome}"`);
	await wait(1500);
	const mock = await mockLog();
	expect(mock.some((l) => / updateNoteFields .*"SentenceAudio": "\[sound:macpopup-sentence-/.test(l)), 'the card got the clip');
	expect(mock.some((l) => / storeMediaFile .*"filename": "yomitan_screenshot_/.test(l)), 'a screenshot stored for the card');
	log('clip 1 voice2');
	log('screenshot voice2');
});
