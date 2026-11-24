// Moving the controller by character (scanResolution "character") in OCR Mode text (fake readings: 明日も晴れる above
// といいね): the cursor box shows on the character at once, and the popup opens on the word there after
// gamepadPopupDelay (1 s); each move closes it and starts the delay again. Down goes to the line below at the same
// place (い, so いね), up back (も). A again ends the focus: no cursor, no popup.
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// timeout: 90

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 300 };
	const line = (text, y) => ({ chars: [...text].map((c, i) => [c, 40 + i * 40, y, 40, 40]) });
	const tap = (control) => gamepadPress([control], { after: 100 });
	// The popup comes 1 s after the cursor stops (gamepadPopupDelay): waited for, up to 2.5 s.
	const popupShown = () => until('the popup', () => popupVisible(), 2500).catch(() => {});
	const check = (when, cursor, highlight) => {
		equal(boxText('gamepad'), cursor, `${when}: the cursor`);
		equal(boxText('scan'), highlight, `${when}: the highlight`);
		equal(popupVisible(), highlight !== '', `${when}: the popup is open`);
	};

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [line('明日も晴れる', 60), line('といいね', 140)] });
	await wait(500);
	await tap('Button A');
	check('A, at once', '明', '');
	await popupShown();
	check('A, then', '', '明日');
	await tap('Direction Pad Right');
	check('right, at once', '日', '');
	await tap('Direction Pad Right');
	check('right again, at once', 'も', '');
	await wait(600);
	check('right again, 0.75 s later', 'も', '');
	await popupShown();
	check('right again, then', '', 'も晴');
	await gamepadPress(['Direction Pad Down']);
	await popupShown();
	check('down, then', '', 'いね');
	await tap('Direction Pad Up');
	check('up, at once', 'も', '');
	await gamepadPress(['Button A']);
	check('A again', '', '');
	await wait(1200);
	check('A again, 1.2 s later', '', '');
	window.__macpopupOcr({ type: 'window', visible: false });
});
