// OCR text that moved by two characters while a popup is open (a fake reading, 80 px to the right): it's drawn at once,
// and the popup's word (晴れ) stays highlighted where it moved, the popup open, with the pointer left on the text (now
// over 日, which isn't looked up) or in the popup.
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "autoHideResults": false, "hidePopupOnCursorExit": false, "scanDelay": 20, "ankiEnabled": false}
// timeout: 60

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	// Characters 40 points apart from (40 + dx, 60).
	const reading = (text, { dx = 0 } = {}) => ({
		type: 'result', width: W.width, height: W.height,
		lines: [{ chars: [...text].map((c, i) => [c, 40 + dx + i * 40, 60, 40, 40]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const text = () => document.querySelector('#ocr-text').textContent;
	const charLeft = (c) => {
		const span = [...document.querySelectorAll('#ocr-text .ocr-char')].find((s) => s.textContent === c);
		return span ? Math.round(span.getBoundingClientRect().left) : null;
	};
	const scanLeft = () => {
		const box = document.querySelector('.highlight-boxes > .scan');
		return box ? Math.round(box.getBoundingClientRect().left) : null;
	};
	const hover = async (i) => {
		await native('debugMouse', { x: at(i).x + 7, y: at(i).y + 5 });
		await wait(100);
		await native('debugMouse', at(i));
		await until('the popup on the hovered word', () => popupVisible() && boxText('scan'));
		await wait(300);
	};
	const popupRect = () => [...document.querySelectorAll('iframe.yomitan-popup')].find((f) => f.style.visibility === 'visible')?.getBoundingClientRect();

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	const base = '明日も晴れるといいね';
	for (const where of ['on the text', 'in the popup']) {
		window.__macpopupOcr(reading(base));
		await wait(300);
		await hover(3);
		if (where === 'in the popup') {
			await native('debugMouse', center(popupRect()));
			await wait(500);
		}
		equal(boxText('scan'), '晴れ', `pointer ${where}, hovered 晴: the highlight`);
		const left = charLeft('晴');
		const boxLeft = scanLeft();
		window.__macpopupOcr(reading(base, { dx: 80 }));
		await wait(800);
		equal(text(), base, `pointer ${where}, moved by two characters: the text`);
		equal(charLeft('晴') - left, 80, `pointer ${where}, moved by two characters: 晴 drawn where it moved (px)`);
		equal(boxText('scan'), '晴れ', `pointer ${where}, moved by two characters: the highlight`);
		equal(scanLeft() - boxLeft, 80, `pointer ${where}, moved by two characters: the highlight moved with it (px)`);
		equal(popupVisible(), true, `pointer ${where}, moved by two characters: the popup is open`);
		window.__macpopupOutsideClick();
		await wait(300);
	}
	window.__macpopupOcr({ type: 'window', visible: false });
});
