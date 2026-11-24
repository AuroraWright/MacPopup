// Put before each test script by launch.sh, which the app then runs in every top-level page (MACPOPUP_TEST_SCRIPT).
// A test calls test(page, body): body runs in that page only, and checks with expect/equal/near. Each check is logged
// ("TEST ok …" or "TEST FAIL …"); launch.sh passes a test that logged "TEST done", at least one check and no failure.
/* exported test, native, log, wait, until, expect, equal, near, lineWith, rangeOf, center, mockLog, popupDocument,
   runFile, logLines, debugRecords, boxText, popupVisible, gamepadPress, windowSteps, windowStep, watch, ocrText, pointerMove,
   pointerClick, driverSaid, processStates, gamePauseNotes,
   sentenceAudioNotes */
'use strict';

function native(cmd, args = {}) {
	return window.webkit.messageHandlers.native.postMessage({ cmd, ...args });
}

function log(message) {
	return native('log', { message: `TEST ${message}` });
}

function wait(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

/** What `find` returns once it's truthy, checked every 100 ms; throws after `timeout` ms, naming `what`. */
async function until(what, find, timeout = 10000) {
	const end = Date.now() + timeout;
	for (;;) {
		const value = await find();
		if (value) return value;
		if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
		await wait(100);
	}
}

const testState = { checks: 0, failures: 0 };

function expect(ok, message) {
	testState.checks++;
	if (!ok) testState.failures++;
	log(`${ok ? 'ok' : 'FAIL'} ${message}`);
	return ok;
}

/** Compared as JSON, which can't tell undefined from undefined or NaN from null: those fail (a field name misspelt). */
function equal(actual, expected, message) {
	const a = JSON.stringify(actual), e = JSON.stringify(expected);
	const odd = expected === undefined || Number.isNaN(actual) || Number.isNaN(expected);
	return expect(a === e && !odd, `${message}: ${a}${a === e && !odd ? '' : ` (expected ${e})`}`);
}

function near(actual, expected, tolerance, message) {
	return expect(Math.abs(actual - expected) <= tolerance,
		`${message}: ${actual} (expected ${expected} ± ${tolerance})`);
}

/** The text box's line with `text` in it, once it's shown. */
function lineWith(text, timeout = 30000) {
	return until(`a line with ${text}`, () =>
		[...document.querySelectorAll('#lines p[data-line-id]')].find((p) => p.textContent.includes(text)), timeout);
}

/** A range over the first `text` in `element`'s text (within one text node). */
function rangeOf(element, text) {
	const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
	for (let node; (node = walker.nextNode()); ) {
		const i = node.data.indexOf(text);
		if (i >= 0) {
			const range = document.createRange();
			range.setStart(node, i);
			range.setEnd(node, i + text.length);
			return range;
		}
	}
	throw new Error(`no ${text} in the element`);
}

function center(rect) {
	return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
}

/** The lines mock.py has logged so far (its requests: "anki <ms> <action> <params>", "yomitan <ms> <path>", "audio <ms> <path>"). */
async function mockLog() {
	const response = await native('http', { url: 'http://127.0.0.1:59879/__log', method: 'GET' });
	return logLines(response.body);
}

/** The popup's document, when one is open. */
function popupDocument() {
	return document.querySelector('iframe.yomitan-popup')?.contentDocument ?? null;
}

/** A file of the run folder (debug.jsonl, app.log, …) as it is now, '' when there's none; needs MOCK_RUN_FILES=1. */
async function runFile(name) {
	const response = await native('http', { url: `http://127.0.0.1:59879/__run/${name}`, method: 'GET' });
	return response.body;
}

/** A log's whole lines: a line still being written (with no line break yet) is left out. */
function logLines(text) {
	return text.split('\n').slice(0, -1).filter(Boolean);
}

/** The debug log's records so far (debug.jsonl, with "ocrShowBoxes": true); needs MOCK_RUN_FILES=1. */
async function debugRecords() {
	return logLines(await runFile('debug.jsonl')).map((line) => JSON.parse(line));
}

/**
 * The text under the overlay's highlight boxes with the class `name` (lib/highlight-boxes.js: 'scan' for the popup's
 * word, 'gamepad' for the controller's cursor), from the caret positions at their edges (the top and bottom ones for
 * boxes over vertical text, class "vertical").
 */
function boxText(name) {
	return [...document.querySelectorAll(`.highlight-boxes > .${name}`)].map((box) => {
		const r = box.getBoundingClientRect();
		const vertical = box.classList.contains('vertical');
		const start = vertical ? document.caretRangeFromPoint(r.left + r.width / 2, r.top + 1)
			: document.caretRangeFromPoint(r.left + 1, r.top + r.height / 2);
		const end = vertical ? document.caretRangeFromPoint(r.left + r.width / 2, r.bottom - 1)
			: document.caretRangeFromPoint(r.right - 1, r.top + r.height / 2);
		if (!start || !end) return '';
		const range = document.createRange();
		range.setStart(start.startContainer, start.startOffset);
		range.setEnd(end.startContainer, end.startOffset);
		return range.toString();
	}).join('');
}

/** Whether a popup shows in the overlay. */
function popupVisible() {
	return [...document.querySelectorAll('iframe.yomitan-popup')].some((f) => f.style.visibility === 'visible');
}

/**
 * Holds game controller `controls` (GameController's names, e.g. 'Button A') for `hold` ms as the host sends them
 * (window.__macpopupGamepad), lets go, then waits `after` ms.
 */
async function gamepadPress(controls, { hold = 50, after = 1000 } = {}) {
	window.__macpopupGamepad(controls);
	await wait(hold);
	window.__macpopupGamepad([]);
	await wait(after);
}

/**
 * The steps a test window has logged so far (`// beside:`, whose output is beside.log): its lines "<ms since 1970> <step>"
 * as { time, step }, times as Date.now()'s. Needs MOCK_RUN_FILES=1.
 */
async function windowSteps() {
	return logLines(await runFile('beside.log')).map((line) => line.match(/^(\d{12,}) (.*)$/))
		.filter(Boolean).map(([, time, step]) => ({ time: Number(time), step }));
}

/** The time of the test window's first step starting with `name`, once it's logged (see windowSteps). */
async function windowStep(name, timeout = 60000) {
	return (await until(`the window's step "${name}"`,
		async () => (await windowSteps()).find((s) => s.step.startsWith(name)), timeout)).time;
}

/**
 * What `read()` returns each time it changes, checked every `every` ms, as { time, value } (the first one too), until
 * `.stop()` (which checks once more, so a value an `until` just saw is in).
 */
function watch(read, every = 50) {
	const changes = [];
	const check = () => {
		const value = read();
		if (!changes.length || JSON.stringify(changes.at(-1).value) !== JSON.stringify(value)) changes.push({ time: Date.now(), value });
	};
	check();
	const timer = setInterval(check, every);
	changes.stop = () => {
		check();
		clearInterval(timer);
	};
	return changes;
}

/** The text OCR Mode shows over the window ('' when none). */
function ocrText() {
	return document.querySelector('#ocr-text')?.textContent ?? '';
}

/**
 * The first line of the driver's log (driver.log) starting with `prefix`, once it's there: for a page that waits on its
 * driver (interactive tests). Needs MOCK_RUN_FILES=1.
 */
async function driverSaid(prefix, timeout = 30000) {
	return until(`the driver's "${prefix}"`,
		async () => logLines(await runFile('driver.log')).find((line) => line.startsWith(prefix)), timeout);
}

let pointerRequests = 0;

/** Asks harness/tools/pointer.py (the driver) to move or click the real pointer: whether it did. */
async function pointerRequest(kind, points, ms) {
	const name = `p${++pointerRequests}`;
	log(`pointer ${kind} ${name} ${innerWidth}x${innerHeight} ${[...points.flatMap((p) => [p.x, p.y]).map(Math.round), ...(ms === undefined ? [] : [ms])].join(' ')}`);
	const answer = await driverSaid(`pointer ${name} `, (ms ?? 0) + 15000).catch((e) => e.message);
	return expect(/^pointer \S+ (moved|clicked)$/.test(answer), `the real pointer: ${answer}`);
}

/**
 * Moves the real pointer from `from` to `to` (this page's points) over `ms`, and waits until it's there: whether it
 * moved (it isn't moved where the test instance's window isn't in front). For interactive tests whose driver is
 * harness/tools/pointer.py, with MOCK_RUN_FILES=1.
 */
function pointerMove(from, to, ms = 300) {
	return pointerRequest('move', [from, to], Math.round(ms));
}

/** Clicks the real pointer at `at` (this page's points), as pointerMove: whether it clicked. */
function pointerClick(at) {
	return pointerRequest('click', [at]);
}

/**
 * The test window's process states so far, as harness/tools/gamestate.py (the driver) logs them every 0.1 s: { time,
 * state } with ps's state ('T…' stopped, 'gone' once it quit), times as Date.now()'s. Needs MOCK_RUN_FILES=1.
 */
async function processStates() {
	return logLines(await runFile('state.log')).map((line) => line.match(/^(\d{12,}) (\S+)/))
		.filter(Boolean).map(([, time, state]) => ({ time: Number(time), state }));
}

/**
 * Game Pause's notes in app.log so far (with "// env: MACPOPUP_DEBUG_OCR=1"): "game paused: …", "game not paused: …"
 * (e.g. "the pause helper isn't allowed"), "the pause helper didn't answer: …", "the pause helper stopped n of m
 * processes", "switched to … while the game was paused". Needs MOCK_RUN_FILES=1.
 */
async function gamePauseNotes() {
	return logLines(await runFile('app.log')).map((line) => line.match(/^\[ocr [\d.]+\] (.*)$/)?.[1])
		.filter((note) => note && /^(game paused|game not paused|the pause helper|switched to )/.test(note));
}

/**
 * Anki Audio's notes in app.log so far (its "[sentence audio] …" lines: "line shown … (line <id>): <text>", "history: …",
 * "<s>s, macpopup-sentence-….m4a", "message: <toast>", …). Needs MOCK_RUN_FILES=1.
 */
async function sentenceAudioNotes() {
	return logLines(await runFile('app.log')).map((line) => line.match(/^\[sentence audio\] (.*)$/)?.[1]).filter(Boolean);
}

function test(page, body) {
	if (window.top !== window || !location.pathname.endsWith(`/${page}.html`)) return;
	(async () => {
		log('ready');
		try {
			await body();
		} catch (e) {
			testState.failures++;
			log(`FAIL ${e.message}`);
		}
		if (testState.checks === 0 && testState.failures === 0) log('FAIL no checks');
		log('done');
	})();
}
