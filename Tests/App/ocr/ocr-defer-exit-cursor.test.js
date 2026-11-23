// A fake OCR reading arrives while a popup is open with its word (晴れ) in place, so it waits; then the popup hides by
// itself with "Hide popup on cursor exit" (autoHideResults off), as the pointer goes into the popup and out to an empty
// place in the window: the popup stays open while the pointer is in it, then closes, and the waiting reading is drawn.
// Without a reading waiting (the baseline), the popup closes the same way. (ocr-defer-exit-autohide: autoHideResults.)
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "autoHideResults": false, "hidePopupOnCursorExit": true, "hidePopupOnCursorExitDelay": 0, "scanDelay": 20, "ankiEnabled": false}
// timeout: 60

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	const reading = (text) => ({
		type: 'result', width: W.width, height: W.height,
		lines: [{ chars: [...text].map((c, i) => [c, 40 + i * 40, 60, 40, 40]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const text = () => document.querySelector('#ocr-text').textContent;
	const check = (when, expected) => {
		equal(text(), expected.text, `${when}: the text`);
		equal(boxText('scan'), expected.highlight, `${when}: the highlight`);
		equal(popupVisible(), expected.popup, `${when}: the popup is open`);
	};
	const hover = async (i) => {
		await native('debugMouse', { x: at(i).x + 7, y: at(i).y + 5 });
		await wait(100);
		await native('debugMouse', at(i));
		await until('the popup on the hovered word', () => popupVisible() && boxText('scan'));
		await wait(300);
	};
	const popupRect = () => [...document.querySelectorAll('iframe.yomitan-popup')].find((f) => f.style.visibility === 'visible')?.getBoundingClientRect();
	const intoPopup = async () => {
		await native('debugMouse', center(popupRect()));
		await wait(500);
	};
	// Above the text, inside the window (the popup is below it).
	const leave = async () => {
		await native('debugMouse', { x: W.x + 700, y: W.y + 15 });
		for (let n = 0; n < 30 && popupVisible(); n++) await wait(100);
		await wait(200);
	};

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr(reading('明日も晴れるといいね'));
	await wait(300);
	await hover(3);
	check('baseline, hovered', { text: '明日も晴れるといいね', highlight: '晴れ', popup: true });
	await intoPopup();
	check('baseline, pointer in the popup', { text: '明日も晴れるといいね', highlight: '晴れ', popup: true });
	await leave();
	check('baseline, pointer on an empty place', { text: '明日も晴れるといいね', highlight: '', popup: false });
	window.__macpopupOutsideClick();
	await wait(300);

	window.__macpopupOcr(reading('今日は雨が降っている'));
	await wait(300);
	await hover(3);
	check('hovered', { text: '今日は雨が降っている', highlight: '雨が', popup: true });
	window.__macpopupOcr(reading('今日は雨が降っていた'));
	await wait(300);
	check('a reading, popup open: it waits', { text: '今日は雨が降っている', highlight: '雨が', popup: true });
	await intoPopup();
	check('pointer in the popup: still waits', { text: '今日は雨が降っている', highlight: '雨が', popup: true });
	await leave();
	check('pointer on an empty place: drawn', { text: '今日は雨が降っていた', highlight: '', popup: false });
	window.__macpopupOcr({ type: 'window', visible: false });
});
