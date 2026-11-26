// Anki Audio's recording ends as "no voice" when the captured app says nothing: with game audio recording off, the shortcut
// (card 333) records the captured app (windows/audiowin.swift, cold: it never plays), and after the 10 s voice wait the
// recording ends as no voice, nothing saved nor given to the card. Expected from research/sentence-audio/novoice.sh
// ("the recording should end as no voice after the 10 s wait"; it had Anki off, which now stops before recording, so
// card 333 is the mock's) and SentenceAudio.swift (AudioRecording: noVoice once voiceWait seconds are recorded, the
// silence filled in while nothing plays). Nothing is played.
// mock: MOCK_RUN_FILES=1 MOCK_EDITOR=closed
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "audiowin", "title": "AudioTest"}, "websocketUrls": [], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioEnabled": true, "sentenceAudioHistory": 0, "sentenceAudioShortcut": null, "sentenceAudioApp": "none", "sentenceAudioOpenKeys": [], "sentenceAudioCloseKeys": [], "sentenceAudioDetectVoice": true, "sentenceAudioPause": 1500, "sentenceAudioVoiceWait": 10, "sentenceAudioPadding": 300, "sentenceAudioPlay": false, "sentenceAudioBacklog": true, "screenshotHistory": 0}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/audiowin.swift")" "$RUN/voice-app.aiff" 0.15 40 cold
// timeout: 60

/** Presses the shortcut for card 333 (on no line Anki Audio knows) 1.5 s after the page is ready, as
 * sentence-audio/run.js did, and waits for the recording's end: its notes from the trigger on, and when it ended. */
async function record() {
	await wait(1500);
	const before = (await sentenceAudioNotes()).length;
	const pressed = Date.now();
	log('trigger');
	await native('cardAdded', { note: 333 });
	await native('debugSentenceAudio');
	const ended = /^(voiceEnded|noVoice|maxLength|shortcut|inputEnded)(, silent)?(, nothing saved)?$/;
	await until('the recording\'s end', async () => (await sentenceAudioNotes()).slice(before).some((n) => ended.test(n)
		|| (/^message: /.test(n) && !/^message: (Listening|Recording)/.test(n))), 30000).catch(() => {});
	const ending = Date.now();
	await wait(2000);
	const notes = (await sentenceAudioNotes()).slice(before);
	log(`Anki Audio: ${JSON.stringify(notes)}`);
	return { notes, end: notes.find((n) => ended.test(n)) ?? '', after: ending - pressed };
}

test('overlay', async () => {
	const { notes, end, after } = await record();
	expect(notes.some((n) => /^recording (audiowin|process \d+)$/.test(n)), 'recording the captured app (audiowin) only');
	expect(/^noVoice(, silent)?, nothing saved$/.test(end), `the recording ended as no voice: "${end}"`);
	expect(after > 9500 && after < 14000, `after the 10 s voice wait: ${after} ms after the press`);
	expect(!(await mockLog()).some((l) => /macpopup-sentence-/.test(l)), 'no sentence audio stored nor given to a card');
});
