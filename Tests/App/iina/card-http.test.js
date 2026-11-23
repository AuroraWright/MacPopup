// IINA's sentence audio and screenshot for a card, test.mkv over HTTP (serve.py on 59885, with Range requests): read by
// ffmpeg over the network. The user's IINA (iina.py; history and recent files off for the run) plays the test video
// muted with its MacPopup plugin on 6680; the box shows line 2 (明日も晴れるといいな。, 6–8.5 s), a popup on 晴 adds a card, and
// the card gets the line's audio with 0.5 s around it (5.5–9 s: silent, the 880 Hz tone from 0.5 to 3.0 s, silent) and
// the frame from its middle (7.25 s), checked by iina-card.py from mock.log. Expected values:
// evals/iina/make-video.sh, e2e-run.sh, streams/e2e.sh (2026-11-10: "audio exact, frame within ±1").
// Opens the user's IINA (muted; not while it runs) and quits it; its settings and plugins are checked unchanged.
// interactive
// mock: MOCK_EDITOR=closed MOCK_SHOT=1 MOCK_ADD_NOTE=444
// setup: python3 -I "$REPO/Tests/App/iina/iina.py" setup test
// beside: python3 -I "$REPO/Tests/App/iina/iina.py" beside
// settings: {"websocketUrls": ["ws://127.0.0.1:6680"], "continuousReconnect": true, "showConnectionErrors": false, "ankiEnabled": true, "checkForDuplicates": false, "ankiRenderTemplatesLocally": true, "sentenceAudioEnabled": false, "sentenceAudioField": "SentenceAudio", "iinaSentenceAudioEnabled": true, "iinaSentenceAudioPadding": 500, "iinaScreenshotEnabled": true, "screenshotFormat": "jpeg", "screenshotQuality": 85, "iinaTranscribe": false, "ankiSuspendNewCards": false, "ankiForceSync": false}
// driver: python3 -I "$REPO/Tests/App/iina/iina-card.py" http
// timeout: 150

test('overlay', async () => {
	const line = await lineWith('明日も晴れる', 90000);
	expect(line.textContent.includes('明日も晴れるといいな'), `line 2 from IINA in the box: "${line.textContent}"`);
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const button = await until('the add button', () => {
		const found = popupDocument()?.querySelector('.entry .action-button[data-action=save-note]');
		return found && !found.disabled && found;
	}, 15000);
	button.click();
	log('adding the card');
	await until('the card added', async () => (await mockLog()).some((l) => l.startsWith('anki-reply addNote ')), 60000)
		.catch((e) => expect(false, e.message));
	await wait(2000);
	const entries = await mockLog();
	const notes = entries.filter((l) => /^anki \d+ addNote /.test(l)).map((l) => JSON.parse(l.replace(/^anki \d+ addNote /, '')));
	equal(notes.length, 1, 'cards added');
	const fields = notes[0]?.note?.fields ?? {};
	expect((fields.Sentence ?? '').replace(/<[^>]*>/g, '').includes('明日も晴れるといいな'), `the Sentence field: ${fields.Sentence}`);
	expect(/^\[sound:macpopup_sentence_[^\]]*\.m4a\]$/.test(fields.SentenceAudio ?? ''), `the SentenceAudio field: ${fields.SentenceAudio}`);
	expect(/^<img src="yomitan_screenshot_[^"]*\.jpg" \/>$/.test(fields.Picture ?? ''), `the Picture field: ${fields.Picture}`);
	const stored = entries.filter((l) => /^anki \d+ storeMediaFile /.test(l)).map((l) => JSON.parse(l.replace(/^anki \d+ storeMediaFile /, '')).filename);
	const named = [fields.SentenceAudio?.match(/\[sound:(.*)\]/)?.[1], fields.Picture?.match(/src="([^"]*)"/)?.[1]];
	expect(named.every((name) => name && stored.includes(name)), `the files stored: ${JSON.stringify(stored)}`);
});
