// Anki Audio's kept game audio, with WebSocket lines: a game (windows/voicegame.swift, quiet music) shows and speaks four
// lines at 8, 14, 17 and 24 s (line 1's voice is cut off by line 2), each sent over WebSocket. At 22.5 s, a card from
// each of lines 0, 1 and 2 in turn presses the sentence audio shortcut (cardAdded + debugSentenceAudio, one at a time),
// then one from line 3 at 27.3 s, while its voice still plays. Lines 0, 2 and 3 get their line's voice, whole, cut from
// the kept audio (line 3's once its voice ends); line 1 is refused as cut off by the next line (the visual novel
// backlog fallback is off). clip-driver.py checks the clips against the voices (corr.swift). Expected as on 2026-11-22
// (evals game-tests README, "Placing change": lines 0, 2, 3 whole from the history, line 1 refused as cut off).
// It plays sound: the test window's music and Kyoko's lines, quietly (volume 0.15), for about 35 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1 MOCK_EDITOR=closed
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "voicegame", "title": "AudioTest"}, "websocketUrls": ["ws://127.0.0.1:59880"], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 5, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": false, "screenshotHistory": 0}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/voicegame.swift")" "$RUN" 0.15 8 14 17 24
// driver: python3 -I "$REPO/Tests/App/anki-audio/clip-driver.py" voice0 voice1 voice2 voice3
// timeout: 120

/** Anki Audio's id for the line with this text (its "line shown" notes; the likest one, from 0 to 1 alike). */
async function lineId(text) {
	const alike = (a) => [...text].filter((c) => a.includes(c)).length / text.length;
	const lines = (await sentenceAudioNotes()).map((n) => n.match(/^line shown [\d.]+ s ago \(line (\d+)\): (.*)$/))
		.filter(Boolean).map(([, id, shown]) => ({ id: Number(id), alike: alike(shown) }));
	return lines.reduce((best, l) => (l.alike > (best?.alike ?? 0) ? l : best), null);
}

/** Presses the shortcut for a card from this line, and waits for how it ended: a clip's note, a reason, a message. */
async function press(id) {
	const before = (await sentenceAudioNotes()).length;
	const clips = (await mockLog()).filter((l) => / storeMediaFile .*"filename": "macpopup-sentence-/.test(l)).length;
	await native('cardAdded', { note: 333, line: id });
	await native('debugSentenceAudio');
	const outcome = await until('Anki Audio', async () => (await sentenceAudioNotes()).slice(before).find((n) =>
		/^[\d.]+s, macpopup-sentence-/.test(n)
		|| (/^message: /.test(n) && !/^message: Waiting for speech to finish/.test(n)) // (shown while it waits, not an outcome)
		|| (/^history: /.test(n) && !/^history: (line \d|voice |waiting |no voice in )/.test(n))), 25000).catch(() => '');
	await wait(1500);
	return { outcome, clip: clips + 1 };
}

test('overlay', async () => {
	const texts = await Promise.all([0, 1, 2, 3].map(async (i) => (await runFile(`voice${i}.txt`)).trim()));
	const start = (await windowStep('line 0 shown', 30000)) - 8000;
	await until('22.5 s into the game', () => Date.now() >= start + 22500, 30000);
	for (const index of [0, 1, 2, 3]) {
		if (index === 3) await until('27.3 s into the game', () => Date.now() >= start + 27300, 30000);
		const line = await lineId(texts[index]);
		expect(line && line.alike >= 0.6, `line ${index} noted as line ${line?.id} (${Math.round((line?.alike ?? 0) * 100)}% alike)`);
		if (!line) continue;
		log(`press line ${index}`);
		const { outcome, clip } = await press(line.id);
		if (index === 1) {
			equal(outcome, 'history: The line’s voice was cut off by the next line', `line ${index}: refused`);
			continue;
		}
		expect(/^[\d.]+s, macpopup-sentence-/.test(outcome), `line ${index}: a clip from the kept audio: "${outcome}"`);
		const updated = (await mockLog()).filter((l) => / updateNoteFields .*\[sound:macpopup-sentence-/.test(l)).length;
		equal(updated, index === 0 ? 1 : index, `cards given sentence audio after line ${index}`);
		log(`clip ${clip} voice${index}`);
	}
	const notes = await sentenceAudioNotes();
	expect(!notes.some((n) => /nothing kept|^recording (voicegame|every app)$/.test(n)), 'no recording made: all from the kept audio');
});
