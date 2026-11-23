// An empty OCR reading (no text) while a popup is open on 晴れ: the popup's word isn't in it, so it's drawn at once (the
// text and the highlight go), and closing the popup leaves nothing to draw.
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "autoHideResults": false, "hidePopupOnCursorExit": false, "scanDelay": 20, "ankiEnabled": false}
// timeout: 60

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	const reading = (text) => ({
		type: 'result', width: W.width, height: W.height,
		lines: [{ chars: [...text].map((c, i) => [c, 40 + i * 40, 60, 40, 40]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const text = () => document.querySelector('#ocr-text').textContent;
	const layerShown = () => !document.querySelector('#ocr-layer').hidden;

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr(reading('明日も晴れるといいね'));
	await wait(300);
	await native('debugMouse', { x: at(3).x + 7, y: at(3).y + 5 });
	await wait(100);
	await native('debugMouse', at(3));
	await until('the popup on 晴', () => popupVisible() && boxText('scan'));
	await wait(300);
	equal(boxText('scan'), '晴れ', 'hovered 晴: the highlight');

	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [] });
	await wait(300);
	equal(text(), '', 'empty reading: the text');
	equal(boxText('scan'), '', 'empty reading: the highlight');
	equal(layerShown(), true, 'empty reading: the layer is shown');

	window.__macpopupOutsideClick();
	await wait(300);
	equal(text(), '', 'closed: the text');
	equal(popupVisible(), false, 'closed: the popup is open');
	window.__macpopupOcr({ type: 'window', visible: false });
});
