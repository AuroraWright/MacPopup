// WebSocket lines between transcribed ones that grow ("Detect sentence ends": a line goes on with the next stretch when
// the pause before it was short, see GrowingLines), on a sound file played in place of an app's audio
// (MACPOPUP_TEST_TRANSCRIPTION_FILE, read from the file, never played): four sentences said by Kyoko in two halves each
// (0.35 s apart, a stretch each with a 200 ms pause; speech.py halves, SaT cloned from the user's too). The page sends a
// numbered WebSocket line ("ウェブソケットの行その<n>です。", mock.py's server) 0.3 s after every third transcribed line
// (the 1st, 4th, …), so that some lines grow with a WebSocket line after the line they grow from and
// some without. The host's lines (its notes, with MACPOPUP_DEBUG_OCR and Anki on) never turn from a WebSocket line into
// a transcribed one or back (a grown line taking the place of the WebSocket line after it); a line that grows with
// none after it takes its place in the box and in the host's lines ("grew"); the box has every WebSocket line once, in
// order, no line twice, and each sentence in its transcribed lines. From evals/transcribe ws-lines.py and
// check-ws-lines.py.
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// setup: python3 -I "$REPO/Tests/App/transcribe/speech.py" halves sat
// env: MACPOPUP_TEST_TRANSCRIPTION_FILE=$RUN/speech.wav MACPOPUP_DEBUG_OCR=1
// settings: {"floatingWindowAudio": true, "transcriptionModel": "soda", "language": "ja", "transcriptionLive": false, "transcriptionSentenceEnds": true, "transcriptionPause": 200, "websocketUrls": ["ws://127.0.0.1:59880"], "ankiEnabled": true, "sentenceAudioEnabled": false, "screenshotHistory": 0, "clipboardMonitor": false, "maxLines": 0, "preventLastDuplicate": 0, "preventGlobalDuplicate": false}
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

const isWebsocket = (text) => text.startsWith('ウェブソケットの行');

test('overlay', async () => {
	const { duration, sentences } = JSON.parse(await runFile('speech.json'));
	await until('the WebSocket connected', async () => (await mockLog()).some((l) => l.startsWith('websocket-connected')), 20000);
	const events = await record();
	let sent = 0;
	const send = () => {
		const line = `ウェブソケットの行その${++sent}です。`;
		void native('http', { url: 'http://127.0.0.1:59881/', body: JSON.stringify(line) });
	};
	const transcript = window.__macpopupTranscript;
	let finalsSeen = 0;
	window.__macpopupTranscript = (...args) => {
		if (finalsSeen++ % 3 === 0) setTimeout(send, 300);
		return transcript(...args);
	};
	await playedThrough(duration);
	await wait(1500);

	const notes = [...(await runFile('app.log')).matchAll(/\] line (\d+) (new|grew|again), sent: (.*)/g)].map((m) => ({ id: m[1], how: m[2], text: m[3] }));
	const first = new Map(), wrong = [];
	for (const note of notes) {
		if (!first.has(note.id)) first.set(note.id, note.text);
		else if (isWebsocket(first.get(note.id)) !== isWebsocket(note.text)) wrong.push(`line ${note.id} was ${first.get(note.id)}, then ${note.how}: ${note.text}`);
	}
	log(`${notes.length} notes, ${first.size} host lines, ${[...first.values()].filter(isWebsocket).length} WebSocket; ${notes.filter((n) => n.how !== 'new').length} grew or again`);
	equal(wrong, [], 'host lines that turned from a WebSocket line into a transcribed one or back');
	const finals = events.filter((e) => e.kind === 'final');
	const earlier = (f) => finals.filter((g) => g.time < f.time).at(-1);
	const websocketSince = (f) => events.some((e) => e.kind === 'added' && isWebsocket(e.text) && e.time < f.time && e.time > (earlier(f)?.time ?? 0));
	const grown = finals.filter((f) => f.grows);
	const afterWebsocket = grown.filter(websocketSince), inPlace = grown.filter((f) => !websocketSince(f));
	log(`grown lines with a WebSocket line since the line they grew from: ${JSON.stringify(afterWebsocket.map((f) => f.text))}; without: ${JSON.stringify(inPlace.map((f) => f.text))}`);
	expect(afterWebsocket.length > 0 && inPlace.length > 0,
		`lines grew with a WebSocket line after the line they grew from (${afterWebsocket.length}) and without (${inPlace.length}): both cases checked`);
	expect(notes.some((n) => n.how === 'grew'), 'the host noted a line that grew in place ("grew")');

	const lines = boxLines();
	log(`lines ${JSON.stringify(lines)}`);
	const left = inPlace.map((f) => earlier(f).text).filter((text) => lines.includes(text));
	equal(left, [], 'lines still in the box that a line grew from in place (no WebSocket line after them)');
	const numbers = lines.filter(isWebsocket).map((l) => Number(l.match(/その(\d+)/)?.[1]));
	equal(numbers, Array.from({ length: sent }, (_, i) => i + 1), 'the WebSocket lines in the box');
	equal(lines.filter((l, i) => lines.indexOf(l) !== i), [], 'lines twice');
	const transcribed = lines.filter((l) => !isWebsocket(l)).join('');
	const found = sentences.map((s) => similarity(s.text, transcribed));
	expect(found.every((f) => f >= 0.6), `each sentence in the transcribed lines: ${found.map((f) => f.toFixed(2)).join(' ')}`);
});
