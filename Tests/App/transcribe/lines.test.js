// "Read text from audio" (Floating Window, Live Caption) on a sound file played in place of an app's audio
// (MACPOPUP_TEST_TRANSCRIPTION_FILE, read from the file, never played): six sentences said by Kyoko 3 s apart over
// synthetic music (speech.py plain music; make-music.py), 4 s of music alone before them and 5 s after. Each sentence
// is a line in the box (most of its characters), no line comes from the music alone, no line twice, the audio button
// ends green (loaded) and was never red, and no toast (a model's error) shows. Live Caption's models are cloned from
// the user's (setup fails without them). From evals/transcribe run.sh and run.js.
// mock: MOCK_RUN_FILES=1
// setup: python3 -I "$REPO/Tests/App/transcribe/speech.py" plain music
// env: MACPOPUP_TEST_TRANSCRIPTION_FILE=$RUN/speech.wav
// settings: {"floatingWindowAudio": true, "transcriptionModel": "soda", "language": "ja", "transcriptionLive": false, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "ankiEnabled": false, "clipboardMonitor": false, "maxLines": 0, "preventLastDuplicate": 0, "preventGlobalDuplicate": false}
// timeout: 120

/** Text without punctuation, spaces, symbols or width differences, for comparing transcripts. */
const plain = (text) => (text ?? '').normalize('NFKC').replace(/[\p{P}\p{Z}\p{C}\p{S}]/gu, '');

/** How much of `expected` is in `got` (longest common subsequence / its length), 0 to 1. */
function similarity(expected, got) {
	const a = [...plain(expected)], b = [...plain(got)];
	if (!a.length) return 0;
	const row = new Array(b.length + 1).fill(0);
	for (const ca of a) {
		let previous = 0;
		for (let j = 1; j <= b.length; j++) [previous, row[j]] = [row[j], ca === b[j - 1] ? previous + 1 : Math.max(row[j], row[j - 1])];
	}
	return row[b.length] / a.length;
}

/** The box's lines (not its highlight boxes' layer, #box-highlights). */
const boxLines = () => [...document.querySelectorAll('#lines > *')].filter((e) => e.id !== 'box-highlights').map((e) => e.textContent.trim());

/** Waits until the file has played through, `after` seconds more (from the last time the app started playing it). */
async function playedThrough(duration, after = 8) {
	let plays = 0, end = 0;
	for (;;) {
		const n = (await runFile('app.log')).split('\n').filter((l) => l.includes('in place of app audio')).length;
		if (n !== plays) [plays, end] = [n, Date.now() + (duration + after) * 1000];
		if (plays && Date.now() > end) return;
		await wait(500);
	}
}

test('overlay', async () => {
	const { duration, sentences } = JSON.parse(await runFile('speech.json'));
	const toasts = [];
	const toast = await until('the page', () => window.__macpopupToast);
	window.__macpopupToast = (message, ...rest) => {
		toasts.push(String(message));
		log(`toast ${message}`);
		return toast(message, ...rest);
	};
	const button = () => {
		const b = document.querySelector('#audio-button');
		return b.classList.contains('text-red-500') ? 'red' : b.classList.contains('text-warning') ? 'yellow' : b.classList.contains('text-green-700') ? 'green' : 'off';
	};
	const colours = watch(button, 100);
	await playedThrough(duration);
	colours.stop();
	log(`audio button ${colours.map((c) => c.value).join(' → ')}`);

	const lines = boxLines();
	log(`lines ${JSON.stringify(lines)}`);
	const found = sentences.map((s) => Math.max(0, ...lines.map((l) => similarity(s.text, l))));
	expect(found.every((f) => f >= 0.6), `each sentence in a line (most of its characters): ${found.map((f) => f.toFixed(2)).join(' ')}`);
	const fromSpeech = lines.map((l) => Math.max(...sentences.map((s) => similarity(l, s.text))));
	expect(fromSpeech.every((f) => f >= 0.5), `no line from the music alone (each line's characters in a sentence): ${fromSpeech.map((f) => f.toFixed(2)).join(' ')}`);
	expect(lines.length >= sentences.length && lines.length <= sentences.length + 2, `${lines.length} lines for ${sentences.length} sentences`);
	equal(lines.filter((l, i) => lines.indexOf(l) !== i), [], 'lines twice');
	expect(button() === 'green' && !colours.some((c) => c.value === 'red'), `the audio button ends green, never red: ${colours.map((c) => c.value).join(' → ')}`);
	equal(toasts, [], 'toasts');
});
