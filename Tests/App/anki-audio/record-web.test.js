// As record-app.test.js, with a captured app whose sound plays in a web view (WKAudioTest.app, made in the run folder
// by wkaudio-app.sh from windows/wkaudio.swift): WebKit plays it from its own processes, which are recorded as the
// app's. The card gets the Japanese line whole, not the English one. Expected from research/sentence-audio/run.sh
// (its "web" case) and AudioTap.swift (an app's helper processes, e.g. WebKit's GPU process, are the app's).
// It plays sound: a Japanese and an English line (say's voices, volume 0.15), about 5 s each.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_EDITOR=closed
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "WKAudioTest", "title": "WKAudioTest"}, "websocketUrls": [], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 0, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": true, "screenshotHistory": 0}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN" && "$REPO/Tests/App/anki-audio/wkaudio-app.sh" "$RUN"
// driver: python3 -I "$REPO/Tests/App/anki-audio/record-driver.py" web --other & python3 -I "$REPO/Tests/App/anki-audio/clip-driver.py" voice-app voice-other; wait
// timeout: 90

/** Presses the shortcut for card 333 (on no line Anki Audio knows) 1.5 s after the page is ready, as
 * sentence-audio/run.js did, and waits for the recording's end: its notes from the trigger on, and when it ended. */
async function record() {
	await wait(1500);
	const before = (await sentenceAudioNotes()).length;
	const pressed = Date.now();
	log('trigger');
	await native('cardAdded', { note: 333 });
	await native('debugSentenceAudio');
	const ended = /^(voiceEnded|noVoice|maxLength|shortcut|inputEnded)(, silent)?(, nothing kept)?$/;
	await until('the recording\'s end', async () => (await sentenceAudioNotes()).slice(before).some((n) => ended.test(n)
		|| (/^message: /.test(n) && !/^message: (Listening|Recording)/.test(n))), 30000).catch(() => {});
	const ending = Date.now();
	await wait(2000);
	const notes = (await sentenceAudioNotes()).slice(before);
	log(`Anki Audio: ${JSON.stringify(notes)}`);
	return { notes, end: notes.find((n) => ended.test(n)) ?? '', after: ending - pressed };
}

test('overlay', async () => {
	const { notes, end } = await record();
	expect(notes.includes('history: Game audio isn’t being kept. Turn it on in Settings → Anki Audio.'),
		'the kept audio is off: recorded instead');
	expect(notes.some((n) => /^recording (WKAudioTest|process \d+)$/.test(n)), 'recording the captured app (WKAudioTest) only');
	equal(end, 'voiceEnded', 'the recording ended with the voice');
	expect(notes.some((n) => /^[\d.]+s, macpopup-sentence-/.test(n)), 'a clip saved');
	expect((await mockLog()).some((l) => / updateNoteFields .*"SentenceAudio": "\[sound:macpopup-sentence-/.test(l)), 'card 333 got it');
	log('clip 1 voice-app');
});
