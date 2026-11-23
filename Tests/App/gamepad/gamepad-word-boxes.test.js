// The controller's word without "Select matched text" (the mock's lookups match 4 characters; scanResolution word):
// its cursor boxes, one per character and none doubled, on a horizontal OCR line (日曜日に, 40 px boxes along the row,
// the bar at the bottom: box-shadow inset 0 -2px), then on a vertical one (down the column, class "vertical", the bar
// on the right: inset -2px 0).
// mock: MOCK_MATCH_LENGTH=4
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "gamepadScanButtons": ["Button A"], "selectMatchedText": false, "scanResolution": "word", "gamePause": false}
// timeout: 60

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 400 };
	const across = (text, y) => ({ chars: [...text].map((c, i) => [c, 40 + i * 40, y, 40, 40]) });
	const down = (text, x) => ({ vertical: true, chars: [...text].map((c, i) => [c, x, 20 + i * 40, 40, 40]) });
	// Each cursor box: its classes, rect and where its bar is (the box-shadow without its color).
	const boxes = () => [...document.querySelectorAll('.highlight-boxes > .gamepad')].map((box) => {
		const r = box.getBoundingClientRect();
		return [box.className, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height),
			getComputedStyle(box).boxShadow.replace(/rgba?\([^)]*\)\s*/, '')];
	});

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [across('日曜日に行く', 60)] });
	await wait(500);
	await gamepadPress(['Button A']);
	equal(boxText('gamepad'), '日曜日に', 'horizontal: the cursor');
	equal(boxes(), [240, 280, 320, 360].map((x) => ['gamepad', x, 360, 40, 40, '0px -2px 0px 0px inset']), 'horizontal: the boxes');
	await wait(500);
	await gamepadPress(['Button A']);
	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [down('日曜日に行く', 400)] });
	await wait(800);
	await gamepadPress(['Button A']);
	equal(boxText('gamepad'), '日曜日に', 'vertical: the cursor');
	equal(boxes(), [320, 360, 400, 440].map((y) => ['gamepad vertical', 600, y, 40, 40, '-2px 0px 0px 0px inset']), 'vertical: the boxes');
	await wait(500);
	window.__macpopupOcr({ type: 'window', visible: false });
});
