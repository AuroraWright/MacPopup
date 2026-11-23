// With "Overwrite sentence audio" off (sentenceAudioOverwrite false), Option-clicking an add button that overwrites a
// card which already has sentence audio keeps that audio, silently: as overwrite-add.test.js, the card (note 333,
// [sound:old.m4a], MOCK_OVER) is overwritten without its line's voice ("no voice asked for"), and nothing is recorded,
// stored or said. Expected from the 2026-11-14 rules (memory: "when off and the card has audio, the popup silently skips
// the recording (no toast, user's wish)") and popup.js saveNote.
// It plays sound: the test window's music and Kyoko's lines, quietly (volume 0.15), for about 35 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed MOCK_OVER=1
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 0, "duplicateBehavior": "overwrite", "sentenceAudioOverwrite": false, "ankiRenderTemplatesLocally": true}
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
	button.dispatchEvent(new (button.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true, altKey: true }));
	const added = await until('the card', async () => (await sentenceAudioNotes()).slice(before).find((n) => n.startsWith('card ')), 10000).catch(() => '');
	expect(/^card 333 added, line \d+: no voice asked for$/.test(added), `the card overwritten: "${added}"`);
	await wait(8000);
	const notes = (await sentenceAudioNotes()).slice(before);
	expect(!notes.some((n) => /^history: |^[\d.]+s, macpopup-sentence-|^shortcut pressed|^message: /.test(n)), `no sentence audio taken nor message: ${JSON.stringify(notes)}`);
	const mock = await mockLog();
	const updates = mock.filter((l) => /^anki \d+ updateNoteFields /.test(l));
	expect(updates.length === 1 && updates[0].includes('"SentenceAudio": "[sound:old.m4a]"'), `note 333 overwritten once, its sentence audio kept: ${updates.map((l) => l.slice(0, 160)).join(' | ')}`);
	expect(!mock.some((l) => /macpopup-sentence-/.test(l)), 'no sentence audio stored nor given to a card');
});
