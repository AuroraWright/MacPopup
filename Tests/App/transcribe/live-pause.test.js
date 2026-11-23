// "Show words as they're heard" (Live Caption) and the box's pause button (clicked in the page: no real pointer), on a
// sound file played in place of an app's audio (MACPOPUP_TEST_TRANSCRIPTION_FILE, read from the file, never played): six
// sentences said by Kyoko 3 s apart (speech.py plain). The box is paused 1 s into the 3rd sentence's live words and
// resumed 1 s into the 5th's. While paused no live words and no lines show, and the 3rd sentence's live line goes when
// its line comes (not shown); after, live words and lines show again: the box has the 1st, 2nd, 5th and 6th sentences
// only, and no live line is left. Checks the review fix "a live line goes when its stretch's text comes while the box is
// paused, and no new live words show while paused" (58aa084). From evals/transcribe fixes-pause.js.
// mock: MOCK_RUN_FILES=1
// setup: python3 -I "$REPO/Tests/App/transcribe/speech.py" plain
// env: MACPOPUP_TEST_TRANSCRIPTION_FILE=$RUN/speech.wav
// settings: {"floatingWindowAudio": true, "transcriptionModel": "soda", "language": "ja", "transcriptionLive": true, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "ankiEnabled": false, "clipboardMonitor": false, "maxLines": 0, "preventLastDuplicate": 0, "preventGlobalDuplicate": false}
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
	const pauseButton = document.querySelector('#pause-button');

	const third = await liveStretch(events, 2);
	await wait(third.time + 1000 - Date.now());
	const before = liveShown();
	pauseButton.click();
	const paused = Date.now();
	log(`paused; live lines ${JSON.stringify(before)}`);
	expect(before.some((l) => l.startsWith(`live-${third.id}:`)), `the 3rd sentence's live line shows when the box is paused: ${JSON.stringify(before)}`);

	const fifth = await liveStretch(events, 4);
	await wait(fifth.time + 1000 - Date.now());
	const atResume = liveShown();
	pauseButton.click();
	const resumed = Date.now();
	log(`resumed; live lines ${JSON.stringify(atResume)}`);

	await playedThrough(duration);
	const lines = boxLines();
	log(`lines ${JSON.stringify(lines)}`);
	const during = events.filter((e) => e.time > paused && e.time < resumed);
	const thirdLine = during.find((e) => e.kind === 'final' && e.endsLive === third.id);
	expect(!!thirdLine, `the 3rd sentence's line came while paused: ${JSON.stringify(thirdLine?.text)}`);
	equal(during.filter((e) => e.kind === 'added').map((e) => e.text), [], 'lines added while paused');
	equal(during.filter((e) => e.kind === 'live-shown').map((e) => e.id), [], 'live lines shown or changed while paused');
	equal(atResume, [], 'live lines shown when resumed (the 3rd sentence\'s went with its line)');
	const after = events.filter((e) => e.time > resumed);
	expect(after.some((e) => e.kind === 'live-shown'), 'live words show again once resumed');
	expect(after.some((e) => e.kind === 'added'), 'lines show again once resumed');
	const found = sentences.map((s) => Math.max(0, ...lines.map((l) => similarity(s.text, l))));
	const expected = [true, true, false, false, true, true];
	expect(found.every((f, i) => (expected[i] ? f >= 0.6 : f < 0.5)),
		`the sentences in the box (expected ${expected}): ${found.map((f) => f.toFixed(2)).join(' ')}`);
	equal(liveShown(), [], 'live lines left');
});
