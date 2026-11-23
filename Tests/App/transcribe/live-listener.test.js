// "Show words as they're heard" (Live Caption) when the listener starts again, on a sound file played in place of an
// app's audio (MACPOPUP_TEST_TRANSCRIPTION_FILE, read from the file, never played): six sentences said by Kyoko 3 s apart
// (speech.py plain). 2 s into the 2nd sentence's live words, the page saves another pause length (transcriptionPause
// 1100, as Settings does), which starts a new listener: the file plays again from its start. The live lines shown go
// at once; after the change every line that ends a live line ends one of the new listener's, with words like its own
// (the old listener's stretches don't remove the new one's live lines, whose numbers start from 0 again), the new
// listener's lines have each sentence, and no live line is left at the end. Checks the review fix "after the listener
// restarts (another pause setting), the old listener's last stretch no longer removes the new one's live line with the
// same number" (58aa084). From evals/transcribe fixes-listener.js.
// mock: MOCK_RUN_FILES=1
// setup: python3 -I "$REPO/Tests/App/transcribe/speech.py" plain
// env: MACPOPUP_TEST_TRANSCRIPTION_FILE=$RUN/speech.wav
// settings: {"floatingWindowAudio": true, "transcriptionModel": "soda", "language": "ja", "transcriptionLive": true, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "ankiEnabled": false, "clipboardMonitor": false, "maxLines": 0, "preventLastDuplicate": 0, "preventGlobalDuplicate": false}
// timeout: 150

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


/** The `n`th stretch (from 0) given live words: its id and when its first words came, once they have. */
async function liveStretch(events, n, timeout = 90000) {
	return until(`live words of the stretch ${n}`, () => {
		const firsts = events.filter((e, i) => e.kind === 'live' && e.text !== null && events.findIndex((f) => f.kind === 'live' && f.id === e.id && f.text !== null) === i);
		return firsts[n] ? { id: firsts[n].id, time: firsts[n].time } : null;
	}, timeout);
}

test('overlay', async () => {
	const { duration, sentences } = JSON.parse(await runFile('speech.json'));
	const events = await record();

	const second = await liveStretch(events, 1);
	await wait(second.time + 2000 - Date.now());
	const before = liveShown();
	const settings = JSON.parse(await native('getSettings'));
	await native('setSettings', { json: JSON.stringify({ ...settings, transcriptionPause: 1100 }) });
	const step = Date.now();
	log(`transcriptionPause 1100 saved; live lines ${JSON.stringify(before)}`);
	expect(before.some((l) => l.startsWith(`live-${second.id}:`)), `the 2nd sentence's live line shows at the change: ${JSON.stringify(before)}`);
	await wait(1500);
	equal(liveShown(), [], 'live lines 1.5 s after the change');

	await playedThrough(duration);
	const plays = (await runFile('app.log')).split('\n').filter((l) => l.includes('in place of app audio')).length;
	equal(plays, 2, 'times the file was played (again from its start after the change)');
	const after = events.filter((e) => e.time > step);
	const finals = after.filter((e) => e.kind === 'final');
	const ended = finals.filter((f) => f.endsLive !== null).map((final) => {
		const words = after.filter((e) => e.kind === 'live' && e.id === final.endsLive && e.text !== null && e.time <= final.time);
		const close = words.length ? similarity(final.text, words.at(-1).text) : 0;
		log(`line ${JSON.stringify(final.text)} ends live line ${final.endsLive}: ${words.length} live updates since the change, ${close.toFixed(2)} alike`);
		return close >= 0.5;
	});
	expect(ended.length >= sentences.length && ended.every(Boolean),
		`each line that ends a live line after the change ends one of the new listener's, with words like its own: ${ended}`);
	const found = sentences.map((s) => Math.max(0, ...finals.map((f) => similarity(s.text, f.text))));
	expect(found.every((f) => f >= 0.6), `each sentence in a line after the change: ${found.map((f) => f.toFixed(2)).join(' ')}`);
	log(`lines ${JSON.stringify(boxLines())}`);
	equal(liveShown(), [], 'live lines left');
});
