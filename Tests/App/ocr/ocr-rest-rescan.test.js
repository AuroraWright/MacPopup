// A pointer that comes to rest on OCR text while the window is changing (fake readings sent to __macpopupOcr): the hover
// looks nothing up then, and the word under the pointer is looked up once the text is current again, without moving it
// (before, the popup only came once the pointer moved again):
//   1  a new reading is drawn: the popup on its word under the pointer (今日も晴れるかな, on 晴)
//   2  the reading comes back unchanged: the popup on 晴
//   3  the pointer left the text before the reading came: no popup
//   4  the reading comes before the scan delay (300 ms) has passed since the hover: the popup waits for the rest of it
//   5  a click outside the popups before the reading (e.g. advancing the game's text): no popup
// (A hover while a reading waits for the popup to close isn't looked up once it's closed: see ocr-defer2's 1.)
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "scanDelay": 300, "autoHideResults": false, "hidePopupOnCursorExit": false, "ankiEnabled": false}
// timeout: 90

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	// Characters 40 points apart from (40, 60).
	const reading = (text) => ({
		type: 'result', width: W.width, height: W.height,
		lines: [{ chars: [...text].map((c, i) => [c, 40 + i * 40, 60, 40, 40]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const off = { x: W.x + 400, y: W.y + 170 };
	const text = () => document.querySelector('#ocr-text').textContent;
	const base = '明日も晴れるといいね';
	// Shows `base`, then the window changes and the pointer comes to rest on 晴 (moving onto it), and nothing is looked up.
	const restWhileChanging = async () => {
		window.__macpopupOutsideClick();
		await native('debugMouse', off);
		window.__macpopupOcr(reading(base));
		await wait(400);
		window.__macpopupOcr({ type: 'changing' });
		await native('debugMouse', { x: at(3).x + 7, y: at(3).y + 5 });
		await wait(50);
		await native('debugMouse', at(3));
		return Date.now();
	};
	const popupAfter = async (when, start, limit = 2000) => {
		try {
			await until(`${when}: the popup`, () => popupVisible() && boxText('scan'), limit);
		} catch {
			return null;
		}
		log(`${when}: popup ${Date.now() - start} ms after the reading, on ${boxText('scan')}`);
		return Date.now() - start;
	};

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });

	// 1
	await restWhileChanging();
	await wait(700);
	equal(popupVisible(), false, '1 resting while the window changes: no popup');
	window.__macpopupOcr(reading('今日も晴れるかな'));
	let start = Date.now();
	let after = await popupAfter('1 new reading', start);
	expect(after !== null, '1 a new reading drawn: the popup comes without moving the pointer');
	equal(text(), '今日も晴れるかな', '1 the new text');
	equal(boxText('scan').startsWith('晴'), true, '1 the word under the pointer is highlighted');
	expect(after === null || after < 500, `1 the scan delay had passed: the popup came at once (${after} ms)`);

	// 2
	await restWhileChanging();
	await wait(700);
	equal(popupVisible(), false, '2 resting while the window changes: no popup');
	window.__macpopupOcr(reading(base));
	start = Date.now();
	after = await popupAfter('2 unchanged', start);
	expect(after !== null, '2 read unchanged: the popup comes without moving the pointer');
	equal(boxText('scan').startsWith('晴'), true, '2 the word under the pointer is highlighted');

	// 3
	await restWhileChanging();
	await wait(400);
	await native('debugMouse', off);
	await wait(300);
	window.__macpopupOcr(reading('今日も晴れるかな'));
	await wait(1200);
	equal(popupVisible(), false, '3 the pointer left the text before the reading: no popup');

	// 4
	const hovered = await restWhileChanging();
	await wait(50);
	window.__macpopupOcr(reading('今日も晴れるかな'));
	start = Date.now();
	await wait(100);
	equal(popupVisible(), false, '4 the reading came 50 ms after the hover: no popup 100 ms later');
	after = await popupAfter('4 early', start);
	expect(after !== null, '4 the popup comes once the scan delay has passed');
	const sinceHover = after === null ? null : start + after - hovered;
	expect(sinceHover === null || sinceHover >= 300, `4 not before the scan delay since the hover (${sinceHover} ms)`);

	// 5
	await restWhileChanging();
	await wait(400);
	window.__macpopupOutsideClick();
	await wait(100);
	window.__macpopupOcr(reading('今日も晴れるかな'));
	await wait(1200);
	equal(popupVisible(), false, '5 a click before the reading: no popup');

	window.__macpopupOutsideClick();
	window.__macpopupOcr({ type: 'window', visible: false });
});
