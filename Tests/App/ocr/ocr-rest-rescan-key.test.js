// A hover while the OCR text changes (fake readings sent to __macpopupOcr), looked up once the text is current (see
// ocr-rest-rescan), with Shift or the middle mouse button as scan inputs and "Scan without mouse move" off: only a hover
// that would have looked something up then counts, and the key must still be held:
//   1  moved onto 晴 with Shift held: the popup once a reading is drawn
//   2  moved onto it without Shift, then Shift pressed at rest (which looks nothing up without moving): no popup
//   3  moved onto it with Shift, then Shift let go at rest: no popup
// A press that may have gone to the game (the host's "input") drops the hover, unless it was only of scan inputs' mouse
// buttons (a game is taken not to use those), e.g. the middle button pressed to scan:
//   4  the middle button: the popup
//   5  the left button: no popup
//   6  the middle and left buttons: no popup
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "scanModifier": "custom", "scanInputs": ["shift", "mouse2"], "scanWithoutMousemove": false, "scanDelay": 20, "autoHideResults": false, "hidePopupOnCursorExit": false, "ankiEnabled": false}
// timeout: 60

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 200 };
	// Characters 40 points apart from (40, 60).
	const reading = (text) => ({
		type: 'result', width: W.width, height: W.height,
		lines: [{ chars: [...text].map((c, i) => [c, 40 + i * 40, 60, 40, 40]) }],
	});
	const at = (i) => ({ x: W.x + 40 + i * 40 + 20, y: W.y + 60 + 20 });
	const off = { x: W.x + 400, y: W.y + 170 };
	// Shows the text, then the window changes and the pointer moves onto 晴 (with Shift held or not).
	const moveWhileChanging = async (shift) => {
		window.__macpopupOutsideClick();
		await native('debugMouse', off);
		window.__macpopupOcr(reading('明日も晴れるといいね'));
		await wait(400);
		window.__macpopupOcr({ type: 'changing' });
		await native('debugMouse', { x: at(3).x + 7, y: at(3).y + 5, shift });
		await wait(50);
		await native('debugMouse', { ...at(3), shift });
		await wait(400);
	};

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });

	// 1
	await moveWhileChanging(true);
	equal(popupVisible(), false, '1 Shift held while the window changes: no popup yet');
	window.__macpopupOcr(reading('今日も晴れるかな'));
	await until('1 the popup', () => popupVisible() && boxText('scan'), 3000).catch(() => {});
	equal(popupVisible(), true, '1 the reading drawn, Shift still held: the popup');
	equal(boxText('scan').startsWith('晴'), true, '1 on the word under the pointer');

	// 2
	await moveWhileChanging(false);
	await native('debugMouse', { ...at(3), shift: true });
	await wait(300);
	window.__macpopupOcr(reading('今日も晴れるかな'));
	await wait(1200);
	equal(popupVisible(), false, '2 Shift pressed only at rest: no popup');

	// 3
	await moveWhileChanging(true);
	await native('debugMouse', { ...at(3), shift: false });
	await wait(300);
	window.__macpopupOcr(reading('今日も晴れるかな'));
	await wait(1200);
	equal(popupVisible(), false, '3 Shift let go at rest: no popup');

	// 4-6
	for (const [n, buttons, popup] of [[4, ['mouse2'], true], [5, ['mouse0'], false], [6, ['mouse0', 'mouse2'], false]]) {
		await moveWhileChanging(true);
		window.__macpopupOcr({ type: 'input', buttons });
		await wait(100);
		window.__macpopupOcr(reading('今日も晴れるかな'));
		if (popup) await until(`${n} the popup`, () => popupVisible() && boxText('scan'), 3000).catch(() => {});
		else await wait(1200);
		equal(popupVisible(), popup, `${n} a press of ${buttons.join(' and ')} before the reading: ${popup ? 'the popup' : 'no popup'}`);
	}

	window.__macpopupOutsideClick();
	window.__macpopupOcr({ type: 'window', visible: false });
});
