// OCR text updates while a popup is open (fake readings sent to __macpopupOcr, WebSocket lines from mock.py). A reading
// waits for the popups to close only when the popup's word (晴れ, hovered on 晴) is still where it was; otherwise it's
// drawn at once:
//   1  other text changed, the word in place: waits (the text and the highlight stay, hovering 明 meanwhile looks
//      nothing up), drawn on closing
//   2  the word changed: drawn at once, the highlight gone
//   3  the word moved by two characters: drawn at once (晴 80 px to the right, still highlighted); moved by 5 px: waits,
//      drawn on closing
//   4  the window read at twice its size, the word in the same place relative to it: waits, drawn on closing
//   5  a reading that waits, then one without the word: drawn at once, and nothing is left to draw on closing
//   6  a WebSocket line (its clearing waits), then its reading: with the word, it waits; without the word, it's drawn at
//      once; with no reading, the text is cleared on closing (from the line on, the base reading matches it and is
//      drawn corrected to it: 明日も晴れるといいな)
//   7  the window goes away while a reading waits (the popup closes, the layer hides, the reading is drawn); then it's
//      back, and its 晴 can be looked up again
// mock: MOCK_WEBSOCKET=1
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "ocrUseWebsocket": true, "websocketUrls": ["ws://127.0.0.1:59880"], "scanDelay": 20, "autoHideResults": false, "hidePopupOnCursorExit": false, "selectMatchedText": true, "ankiEnabled": false}
// timeout: 120

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	// Characters 40 points apart from (40 + dx, 60), in a window read at `scale` times its size.
	const reading = (text, { dx = 0, scale = 1 } = {}) => ({
		type: 'result', width: W.width * scale, height: W.height * scale,
		lines: [{ chars: [...text].map((c, i) => [c, (40 + dx + i * 40) * scale, 60 * scale, 40 * scale, 40 * scale]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const text = () => document.querySelector('#ocr-text').textContent;
	const layerShown = () => !document.querySelector('#ocr-layer').hidden;
	// Where the OCR text's first `c` is drawn (its left edge), or null.
	const charLeft = (c) => {
		const span = [...document.querySelectorAll('#ocr-text .ocr-char')].find((s) => s.textContent === c);
		return span ? Math.round(span.getBoundingClientRect().left) : null;
	};
	const scanLeft = () => {
		const box = document.querySelector('.highlight-boxes > .scan');
		return box ? Math.round(box.getBoundingClientRect().left) : null;
	};
	const check = (when, expected) => {
		equal(text(), expected.text, `${when}: the text`);
		equal(boxText('scan'), expected.highlight, `${when}: the highlight`);
		equal(popupVisible(), expected.popup, `${when}: the popup is open`);
		if ('layer' in expected) equal(layerShown(), expected.layer, `${when}: the layer is shown`);
	};
	const hover = async (i) => {
		// From elsewhere first: a scan needs the pointer to move.
		await native('debugMouse', { x: at(i).x + 7, y: at(i).y + 5 });
		await wait(100);
		await native('debugMouse', at(i));
		await until('the popup on the hovered word', () => popupVisible() && boxText('scan'));
		// The last move's lookup (after the scan delay) is done.
		await wait(300);
	};
	const show = async (r) => {
		window.__macpopupOcr(r);
		await wait(300);
	};
	const close = async () => {
		window.__macpopupOutsideClick();
		await wait(300);
	};
	const sendLine = async (line) => {
		const before = document.querySelectorAll('#lines p[data-line-id]').length;
		await native('http', { url: 'http://127.0.0.1:59881/', body: JSON.stringify(line), timeout: 5 });
		await until(`the WebSocket line ${line}`, () => document.querySelectorAll('#lines p[data-line-id]').length > before, 5000);
		await wait(300);
	};

	await wait(2000);
	await until('the WebSocket connection', async () => (await mockLog()).some((l) => l.startsWith('websocket-connected')), 15000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	const base = '明日も晴れるといいね';
	// Shows the base reading and hovers 晴. Once the WebSocket line 明日も晴れるといいな has come, the reading matches it
	// and is drawn corrected to it (`shown`).
	const start = async (n, shown = base) => {
		await show(reading(base));
		await hover(3);
		check(`${n} hovered 晴`, { text: shown, highlight: '晴れ', popup: true, layer: true });
	};

	await start(1);
	await show(reading('明日も晴れるといいな'));
	check('1 other text changed', { text: base, highlight: '晴れ', popup: true });
	await native('debugMouse', at(0));
	await wait(800);
	check('1 hovered 明 meanwhile (not looked up)', { text: base, highlight: '晴れ', popup: true });
	await close();
	check('1 closed', { text: '明日も晴れるといいな', highlight: '', popup: false });

	await start(2);
	await show(reading('明日も曇るといいね'));
	equal(text(), '明日も曇るといいね', '2 the word changed: drawn at once');
	equal(boxText('scan'), '', '2 the word changed: the highlight');
	await close();

	await start(3);
	const left = charLeft('晴');
	await show(reading(base, { dx: 80 }));
	equal(charLeft('晴') - left, 80, '3 moved by two characters: 晴 drawn where it moved (px)');
	equal(boxText('scan'), '晴れ', '3 moved by two characters: the highlight');
	equal(scanLeft() - left, 80, '3 moved by two characters: the highlight moved with it (px)');
	await close();
	await start(3);
	await show(reading(base, { dx: 5 }));
	equal(charLeft('晴') - left, 0, '3 moved by 5 px: 晴 not drawn again yet (px)');
	check('3 moved by 5 px', { text: base, highlight: '晴れ', popup: true });
	await close();
	equal(charLeft('晴') - left, 5, '3 closed: drawn 5 px to the right (px)');

	await start(4);
	await show(reading('明日も晴れるといいな', { scale: 2 }));
	check('4 read at twice the size', { text: base, highlight: '晴れ', popup: true });
	await close();
	check('4 closed', { text: '明日も晴れるといいな', highlight: '', popup: false });

	await start(5);
	await show(reading('明日も晴れるといいな'));
	check('5 a reading that waits', { text: base, highlight: '晴れ', popup: true });
	await show(reading('今日は雨が降っている'));
	equal(text(), '今日は雨が降っている', '5 then one without the word: drawn at once');
	equal(boxText('scan'), '', '5 then one without the word: the highlight');
	await close();
	check('5 closed', { text: '今日は雨が降っている', highlight: '', popup: false });

	await start(6);
	await sendLine('明日も晴れるといいな');
	check('6 WebSocket line', { text: base, highlight: '晴れ', popup: true });
	await show(reading('明日も晴れるといいな'));
	check('6 its reading, with the word', { text: base, highlight: '晴れ', popup: true });
	await close();
	check('6 closed', { text: '明日も晴れるといいな', highlight: '', popup: false });
	await start(6, '明日も晴れるといいな');
	await sendLine('今日は雨が降っている');
	await show(reading('今日は雨が降っている'));
	equal(text(), '今日は雨が降っている', '6 another line, its reading without the word: drawn at once');
	equal(boxText('scan'), '', '6 another line, its reading without the word: the highlight');
	await close();
	await start(6, '明日も晴れるといいな');
	await sendLine('明後日は曇りだ');
	check('6 a line, no reading', { text: '明日も晴れるといいな', highlight: '晴れ', popup: true });
	await close();
	check('6 closed: cleared', { text: '', highlight: '', popup: false });

	await start(7, '明日も晴れるといいな');
	await show(reading('明日も晴れるといいな'));
	check('7 a reading that waits', { text: '明日も晴れるといいな', highlight: '晴れ', popup: true });
	window.__macpopupOcr({ type: 'window', visible: false });
	await wait(300);
	check('7 window gone', { text: '明日も晴れるといいな', highlight: '', popup: false, layer: false });
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	await wait(300);
	check('7 window back', { text: '明日も晴れるといいな', highlight: '', popup: false, layer: true });
	await hover(3);
	check('7 hovered 晴', { text: '明日も晴れるといいな', highlight: '晴れ', popup: true });

	window.__macpopupOcr({ type: 'window', visible: false });
});
