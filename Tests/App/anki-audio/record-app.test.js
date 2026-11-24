// Anki Audio records the captured app's audio only: with the kept audio off, the shortcut (card 333, the newest) records
// the visual novel backlog's way while the captured app (windows/audiowin.swift, its audio output open from the start,
// as a game with music) says a Japanese line at 7.5 s and another app (afplay) an English one at 2.2 s, both quietly
// (record-driver.py). The recording is of the captured app alone, ends once its voice does, and the card gets a clip
// with the Japanese line whole and not the English one (clip-driver.py, corr.swift). Expected from
// evals/sentence-audio/run.sh (its "app" case) and SentenceAudio.swift (AudioRecording).
// It plays sound: a Japanese and an English line (say's voices, volume 0.15), about 5 s each.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_EDITOR=closed
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "audiowin", "title": "AudioTest"}, "websocketUrls": [], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 0, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": true, "screenshotHistory": 0}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/audiowin.swift")" "$RUN/voice-app.aiff" 0.15 40
// driver: python3 -I "$REPO/Tests/App/anki-audio/record-driver.py" app --other & a=$!; python3 -I "$REPO/Tests/App/anki-audio/clip-driver.py" voice-app voice-other; b=$?; wait $a; exit $(( $? | b ))
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
	expect(notes.some((n) => /^recording (audiowin|process \d+)$/.test(n)), 'recording the captured app (audiowin) only');
	equal(end, 'voiceEnded', 'the recording ended with the voice');
	expect(notes.some((n) => /^[\d.]+s, macpopup-sentence-/.test(n)), 'a clip saved');
	expect((await mockLog()).some((l) => / updateNoteFields .*"SentenceAudio": "\[sound:macpopup-sentence-/.test(l)), 'card 333 got it');
	log('clip 1 voice-app');
});
