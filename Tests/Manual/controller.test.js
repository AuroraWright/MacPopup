// A real controller, from setting it up to looking up words with it. The driver has the person connect one and set it
// up in Settings → Controllers (Set Up…, each control pressed until it's checked, Done), then record the Controller
// scan key in Scanning (Record Buttons). Then the page asks for each step: the scan buttons give the text box focus
// with the cursor on its first character, three presses of the D-pad's right move it three characters, the left stick
// moves it back, and the popup opens once it rests; the scan buttons again end the focus. A game doesn't see the
// controller while MacPopup holds it and does again after: tools/gc-watch.swift watches GameController from the
// background, as a game would (nothing while the text box has focus, the presses after). About 5 minutes.
// Needs a person at the Mac with a controller (DualShock 4/DualSense, Switch Pro Controller or Joy-Con, Xbox, 8BitDo).
// interactive
// mock: MOCK_RUN_FILES=1
// env: MACPOPUP_TEST_CONTROLLERS=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "gamepadLayouts": {}, "gamepadScanButtons": [], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// driver: python3 -I "$REPO/Tests/Manual/controller-driver.py"
// timeout: 1500

// Opens Settings, where the driver has the controller set up first.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));

/**
 * The character index of the controller's cursor in the text, or null when it has none: the character whose box is the
 * cursor's, compared by place (not by what's at the point, which is the popup once it opens over the line). With
 * "Select matched text" (the default) the cursor's box goes while the popup is open, and the matched word's ("scan"),
 * which starts at the cursor, shows where it is.
 */
function cursorIndex() {
	const box = document.querySelector('.highlight-boxes > .gamepad') ?? document.querySelector('#box-highlights > .scan');
	if (!box) return null;
	const r = box.getBoundingClientRect();
	const walker = document.createTreeWalker(document.querySelector('#lines'), NodeFilter.SHOW_TEXT,
		{ acceptNode: (node) => (node.parentElement.closest('.highlight-boxes') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) });
	let index = 0;
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		for (let i = 0; i < node.length; i++, index++) {
			const range = document.createRange();
			range.setStart(node, i);
			range.setEnd(node, i + 1);
			const c = range.getBoundingClientRect();
			if (Math.abs(c.left - r.left) < 3 && c.top < r.bottom && c.bottom > r.top) return index;
		}
	}
	return null;
}

/** Logs an ask for the person (the driver shows it) and waits for `find()` to be truthy: its value, or null. */
async function ask(text, what, find, timeout = 120000) {
	log(`ask: ${text}`);
	return until(what, find, timeout).catch(() => null);
}

test('overlay', async () => {
	await lineWith('明日も晴れるといいね');
	await driverSaid('settings done', 900000);
	const settings = JSON.parse(await native('getSettings'));
	const combo = (settings.gamepadScanButtons ?? []).join(' + ');
	expect(combo, `the scan buttons are set: ${combo}`);

	const start = await ask(`Press your scan buttons (${combo}): a cursor appears on the text box's first character.`,
		'the cursor', () => cursorIndex() !== null);
	expect(start, 'the scan buttons give the text box focus');
	await wait(500);
	equal(cursorIndex(), 0, 'the cursor starts on the first character');

	await ask('Press right on the D-pad three times, one press at a time.', 'three moves right',
		() => cursorIndex() >= 3, 90000);
	await wait(1500);
	equal(cursorIndex(), 3, 'after three presses of the D-pad right');

	const before = cursorIndex() ?? 3;
	await ask('Push the left stick to the left briefly, then let go.', 'a move left', () => cursorIndex() < before, 90000);
	await wait(1500);
	const after = cursorIndex();
	expect(after !== null && after < before, `the left stick moved the cursor left: ${before} → ${after}`);

	log('ask: Leave the controller for a moment: the popup opens on the cursor.');
	const popup = await until('the popup', () => popupVisible(), 10000).catch(() => false);
	expect(popup, 'the popup opens once the cursor rests');

	log(`ask: For the next 8 seconds, press some other buttons than ${combo} (e.g. the face buttons) a few times.`);
	await wait(1000);
	// The presses MacPopup got meanwhile, so that a game seeing nothing (the driver's check) means something.
	const forward = window.__macpopupGamepad;
	let presses = 0;
	window.__macpopupGamepad = (controls, ...rest) => {
		if (controls.length) presses++;
		return forward(controls, ...rest);
	};
	log(`held from ${Date.now()}`);
	await wait(8000);
	log(`held to ${Date.now()}`);
	window.__macpopupGamepad = forward;
	expect(presses > 0, `buttons pressed while the text box had focus: ${presses} changes`);
	expect(cursorIndex() !== null, 'the text box still has focus after the other buttons');

	const ended = await ask(`Press ${combo} again: the cursor and the popup go.`, 'the focus ending',
		() => cursorIndex() === null && !popupVisible());
	expect(ended, 'the scan buttons again end the focus and close the popup');

	await wait(2000);
	log('ask: For the next 8 seconds, press some buttons again, as before.');
	await wait(1000);
	log(`free from ${Date.now()}`);
	await wait(8000);
	log(`free to ${Date.now()}`);
	log('ask: Done: thank you. You can put the controller down.');
	log('done');
});
