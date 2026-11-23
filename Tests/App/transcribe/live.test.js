// "Show words as they're heard" (Live Caption) on a sound file played in place of an app's audio
// (MACPOPUP_TEST_TRANSCRIPTION_FILE, read from the file, never played): six sentences said by Kyoko 3 s apart
// (speech.py plain). Each sentence's words show as a live line at least a second before its line comes, the line takes
// the live line's place (its text close to the live line's last), lines don't slide in, each sentence is a line, no
// line twice, and no live line is left at the end. Live Caption's models are cloned from the user's (setup fails without
// them). From scratch-tools/transcribe run-live.js and fixes-none.js (no steps).
// mock: MOCK_RUN_FILES=1
// setup: python3 -I "$REPO/Tests/App/transcribe/speech.py" plain
// env: MACPOPUP_TEST_TRANSCRIPTION_FILE=$RUN/speech.wav
// settings: {"floatingWindowAudio": true, "transcriptionModel": "soda", "language": "ja", "transcriptionLive": true, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "ankiEnabled": false, "clipboardMonitor": false, "maxLines": 0, "preventLastDuplicate": 0, "preventGlobalDuplicate": false, "enableLineAnimation": true}
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

/** The box's lines (not its highlight boxes' layer, #box-highlights, nor live lines). */
const boxLines = () => [...document.querySelectorAll('#lines > *')]
	.filter((e) => e.id !== 'box-highlights' && !e.classList.contains('live-line')).map((e) => e.textContent.trim());
const liveShown = () => [...document.querySelectorAll('#lines > .live-line')].map((e) => `${e.dataset.lineId}:${e.textContent.trim()}`);

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

/**
 * Logs and keeps what the host hands the page: live words ({kind: 'live', id, text}) and lines ({kind: 'final', text,
 * endsLive}), and the lines added to the box ({kind: 'added', slides, text}), each with its time.
 */
async function record() {
	const events = [];
	const started = Date.now();
	const note = (event) => {
		events.push({ time: Date.now(), ...event });
		log(`${event.kind} ${((Date.now() - started) / 1000).toFixed(2)} ${JSON.stringify(event)}`);
	};
	await until('the page', () => window.__macpopupLive && window.__macpopupTranscript);
	const live = window.__macpopupLive, transcript = window.__macpopupTranscript;
	window.__macpopupLive = (id, text) => {
		note({ kind: 'live', id, text });
		return live(id, text);
	};
	window.__macpopupTranscript = (text, age, grows, endsLive) => {
		note({ kind: 'final', text, endsLive, grows });
		return transcript(text, age, grows, endsLive);
	};
	new MutationObserver((mutations) => {
		for (const mutation of mutations) for (const node of mutation.addedNodes) {
			if (node.nodeType !== 1 || node.id === 'box-highlights') continue;
			const slides = node.classList.contains('line-enter') || node.classList.contains('line-enter-vertical');
			const event = { kind: 'added', slides, text: node.textContent.trim() };
			// (Live lines are replaced at each change: kept, not logged.)
			if (node.classList.contains('live-line')) events.push({ time: Date.now(), kind: 'live-shown', id: node.dataset.lineId });
			else note(event);
		}
	}).observe(document.querySelector('#lines'), { childList: true });
	return events;
}

test('overlay', async () => {
	const { duration, sentences } = JSON.parse(await runFile('speech.json'));
	const events = await record();
	await playedThrough(duration);
	const lines = boxLines();
	log(`lines ${JSON.stringify(lines)}`);

	const finals = events.filter((e) => e.kind === 'final');
	const ended = finals.map((final) => {
		const words = events.filter((e) => e.kind === 'live' && e.id === final.endsLive && e.text !== null && e.time <= final.time);
		const ahead = words.length ? (final.time - words[0].time) / 1000 : null;
		const close = words.length ? similarity(final.text, words.at(-1).text) : 0;
		log(`line ${JSON.stringify(final.text)} for live line ${final.endsLive}: words ${ahead?.toFixed(2)} s before, ${close.toFixed(2)} alike`);
		return ahead !== null && ahead >= 1 && close >= 0.5;
	});
	expect(finals.length >= sentences.length && ended.every(Boolean),
		`each line came after its live line's words (at least 1 s before, the line close to their last text): ${ended}`);
	const shownLive = new Set(events.filter((e) => e.kind === 'live-shown').map((e) => e.id));
	expect(shownLive.size >= sentences.length, `live lines shown: ${[...shownLive]}`);
	const added = events.filter((e) => e.kind === 'added');
	equal(added.filter((e) => e.slides).map((e) => e.text), [], 'lines that slid in');
	const found = sentences.map((s) => Math.max(0, ...lines.map((l) => similarity(s.text, l))));
	expect(found.every((f) => f >= 0.6), `each sentence in a line (most of its characters): ${found.map((f) => f.toFixed(2)).join(' ')}`);
	equal(lines.filter((l, i) => lines.indexOf(l) !== i), [], 'lines twice');
	equal(liveShown(), [], 'live lines left');
});
