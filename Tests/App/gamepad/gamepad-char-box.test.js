// Moving the controller by character (scanResolution "character") in the text box: the cursor box shows on the
// character at once, and the popup opens on the word there after gamepadPopupDelay (1 s), the cursor box giving way to
// the popup's highlight; each move closes it and starts the delay again (so 0.75 s after the second of two quick moves
// it's still closed, 1.25 s after, open). Holding right moves on (repeats), the popup opening 1 s after it's let go.
// A again ends the focus: no cursor, no popup.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// timeout: 90

test('overlay', async () => {
	await lineWith('明日も晴れるといいね');
	await wait(500);
	const text = '明日も晴れるといいね';
	const tap = (control) => gamepadPress([control], { after: 100 });
	const check = (when, cursor, highlight) => {
		equal(boxText('gamepad'), cursor, `${when}: the cursor`);
		equal(boxText('scan'), highlight, `${when}: the highlight`);
		equal(popupVisible(), highlight !== '', `${when}: the popup is open`);
	};

	await tap('Button A');
	check('A, at once', '明', '');
	await wait(1100);
	check('A, 1.25 s later', '', '明日');
	await tap('Direction Pad Right');
	check('right, at once', '日', '');
	await tap('Direction Pad Right');
	check('right again, at once', 'も', '');
	await wait(600);
	check('right again, 0.75 s later', 'も', '');
	await wait(500);
	check('right again, 1.25 s later', '', 'も晴');
	await tap('Direction Pad Left');
	check('left, at once', '日', '');
	window.__macpopupGamepad(['Direction Pad Right']);
	await wait(900);
	window.__macpopupGamepad([]);
	const held = boxText('gamepad');
	expect(text.indexOf(held) >= 4 && held.length === 1, `right held 900 ms: the cursor repeated, from 日 to ${held}`);
	equal(popupVisible(), false, 'right held 900 ms: the popup is open');
	await wait(1100);
	check('then 1.1 s later', '', text.slice(text.indexOf(held), text.indexOf(held) + 2));
	await gamepadPress(['Button A']);
	check('A again', '', '');
	await wait(1200);
	check('A again, 1.2 s later', '', '');
});
