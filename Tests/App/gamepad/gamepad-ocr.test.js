// The controller in OCR Mode text (fake readings: 明日も晴れる above といいね): A gives it focus on the first line's
// start; right moves along the line, down goes to the line below at the same place (and no further from the last line),
// up back, left; A again ends the focus. The popup's word is highlighted by one box per character, over the characters
// read (40 px apart from the window's 240, 360).
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "gamepadOcrStart": "bottom", "scanResolution": "character", "gamePause": false}
// timeout: 90

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 300 };
	const line = (text, y, dx = 0) => ({ chars: [...text].map((c, i) => [c, 40 + dx + i * 40, y, 40, 40]) });
	const popupWord = async () => {
		await until('the popup', () => popupVisible() && boxText('scan'), 3000).catch(() => {});
		return popupVisible() ? boxText('scan') : '';
	};
	const boxes = () => [...document.querySelectorAll('.highlight-boxes > .scan')].map((b) => {
		const r = b.getBoundingClientRect();
		return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
	});
	const check = async (when, word, at) => {
		equal(await popupWord(), word, `${when}: the popup's word`);
		equal(boxes(), at.map(([x, y]) => [x, y, 40, 40]), `${when}: its boxes`);
	};

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [line('明日も晴れる', 60), line('といいね', 140)] });
	await wait(500);
	await gamepadPress(['Button A'], { after: 100 });
	await check('A', '明日', [[240, 360], [280, 360]]);
	await gamepadPress(['Direction Pad Right'], { after: 100 });
	await check('right', '日も', [[280, 360], [320, 360]]);
	await gamepadPress(['Direction Pad Down'], { after: 100 });
	await check('down', 'いい', [[280, 440], [320, 440]]);
	await gamepadPress(['Direction Pad Down'], { after: 1000 });
	await check('down at the last line', 'いい', [[280, 440], [320, 440]]);
	await gamepadPress(['Direction Pad Up'], { after: 100 });
	await check('up', '日も', [[280, 360], [320, 360]]);
	await gamepadPress(['Direction Pad Left'], { after: 100 });
	await check('left', '明日', [[240, 360], [280, 360]]);
	await gamepadPress(['Button A']);
	equal(boxText('scan'), '', 'A again: the highlight');
	equal(popupVisible(), false, 'A again: the popup is open');
	window.__macpopupOcr({ type: 'window', visible: false });
});
