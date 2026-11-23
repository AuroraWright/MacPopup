// A plain click on a popup's add button (no Option) adds the card without its line's voice: as option-add.test.js (a
// popup on line 2 once line 3 shows), the click without altKey. The card (note 444) is noted with "no voice asked for",
// and no sentence audio is stored nor given to a card. Expected from evals game-tests optrun.sh's Option false
// case and SentenceAudioController.cardAdded.
// It plays sound: the test window's music and Kyoko's lines, quietly (volume 0.15), for about 35 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 0, "ankiRenderTemplatesLocally": true}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/voicegame.swift")" "$RUN" 0.15 8 14 17 24
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
	button.click();
	const added = await until('the card', async () => (await sentenceAudioNotes()).slice(before).find((n) => n.startsWith('card ')), 10000).catch(() => '');
	expect(/^card 444 added, line \d+: no voice asked for$/.test(added), `the card added: "${added}"`);
	await wait(8000);
	const notes = (await sentenceAudioNotes()).slice(before);
	expect(!notes.some((n) => /^history: |^[\d.]+s, macpopup-sentence-|^shortcut pressed/.test(n)), `no sentence audio taken: ${JSON.stringify(notes)}`);
	const mock = await mockLog();
	expect(mock.some((l) => / addNote /.test(l)), 'the card added to Anki');
	expect(!mock.some((l) => /macpopup-sentence-/.test(l)), 'no sentence audio stored nor given to a card');
});
