// Put before each test script by launch.sh, which the app then runs in every top-level page (MACPOPUP_TEST_SCRIPT).
// A test calls test(page, body): body runs in that page only, and checks with expect/equal/near. Each check is logged
// ("TEST ok …" or "TEST FAIL …"); launch.sh passes a test that logged "TEST done", at least one check and no failure.
/* exported test, native, log, wait, until, expect, equal, near, lineWith, rangeOf, center, mockLog, popupDocument,
   runFile, debugRecords, boxText, popupVisible, gamepadPress */
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

function equal(actual, expected, message) {
	const a = JSON.stringify(actual), e = JSON.stringify(expected);
	return expect(a === e, `${message}: ${a}${a === e ? '' : ` (expected ${e})`}`);
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
	return response.body.split('\n').filter(Boolean);
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

/** The debug log's records so far (debug.jsonl, with "ocrShowBoxes": true); needs MOCK_RUN_FILES=1. */
async function debugRecords() {
	return (await runFile('debug.jsonl')).split('\n').filter(Boolean).map((line) => JSON.parse(line));
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
