// The controller in the text box (scan buttons: Button A). A with B isn't the scan key; A held for a while, sent again
// and again by the host (as when a reopened controller reports it), toggles focus once, at the release. With focus, the
// popup opens on the word at the cursor (明日 first), and the direction pad and the left stick move it a character at a
// time (not past the start); held, the direction repeats (the popup waits for it to stop); the right stick moves too
// (a Joy-Con on its own has only one stick; see moveDirection in overlay.js). A again ends the focus, and directions
// then do nothing.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// timeout: 90

test('overlay', async () => {
	await lineWith('明日も晴れるといいね');
	await wait(500);
	const text = '明日も晴れるといいね';
	// The popup's word, once it opens (it waits for the controller to rest), or '' when none opens.
	const popupWord = async () => {
		await until('the popup', () => popupVisible() && boxText('scan'), 3000).catch(() => {});
		return popupVisible() ? boxText('scan') : '';
	};
	const nothing = (when) => {
		equal(boxText('scan'), '', `${when}: the highlight`);
		equal(boxText('gamepad'), '', `${when}: the controller's cursor`);
		equal(popupVisible(), false, `${when}: the popup is open`);
	};

	await gamepadPress(['Button A', 'Button B']);
	nothing('A + B (not the scan key)');
	for (let n = 0; n < 5; n++) {
		window.__macpopupGamepad(['Button A']);
		await wait(100);
	}
	await wait(500);
	nothing('A held, before release');
	window.__macpopupGamepad([]);
	equal(await popupWord(), '明日', 'A released: the popup\'s word');

	for (const [controls, word, when] of [
		[['Direction Pad Right'], '日も', 'right'],
		[['Left Thumbstick Right'], 'も晴', 'left stick right'],
		[['Direction Pad Left'], '日も', 'left'],
		[['Direction Pad Left'], '明日', 'left'],
		[['Direction Pad Left'], '明日', 'left at the start'],
	]) {
		await gamepadPress(controls, { after: 100 });
		equal(await popupWord(), word, `${when}: the popup's word`);
	}

	window.__macpopupGamepad(['Direction Pad Right']);
	await wait(900);
	window.__macpopupGamepad([]);
	await wait(100);
	equal(popupVisible(), false, 'right held 900 ms: the popup waits');
	const held = await popupWord();
	// Moves at 0, 400, 550, 700 and 850 ms; each waits for the one before it.
	expect(text.indexOf(held) >= 3 && held.length === 2, `right held 900 ms: the cursor repeated, from 明 to ${held[0]} (${held})`);
	await gamepadPress(['Right Thumbstick Left'], { after: 100 });
	const back = text.indexOf(held) - 1;
	equal(await popupWord(), text.slice(back, back + 2), 'right stick left: the popup\'s word, a character back');

	await gamepadPress(['Button A']);
	nothing('A again (focus off)');
	await gamepadPress(['Direction Pad Right'], { after: 1500 });
	nothing('right without focus');
});
