// A screenshot of the captured window and popups closing (after evals/harness/shot-run.sh), with OCR Mode on
// Live Text (pinned) reading windows/shotview.swift: the Anki screenshot is the window alone, at 1x its size in points
// for "1x" and for no resolution, and at its backing scale for "full" (rounded to even pixels); a popup on the OCR text's
// 手 closes once the window is reported hidden; then, with the Floating Window, a popup on a line's 手 closes on a
// space change. (The hiding and the space change are the page's handlers called here, as the app calls them: the app
// noticing them isn't tested.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "shotview", "title": "Shot Test"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "scanDelay": 20, "scanModifier": "none", "autoHideResults": false, "hidePopupOnCursorExit": false, "ankiEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/shotview.swift")" "Shot Test"
// timeout: 90

test('overlay', async () => {
	const shown = (await until('the window shown', async () => (await windowSteps()).find((s) => s.step.startsWith('shown ')), 30000)).step;
	const [, width, height, scale] = shown.match(/^shown (\d+)x(\d+) scale ([\d.]+)$/).map(Number);
	const even = (points, factor) => 2 * Math.round(points * factor / 2);

	// 1. Screenshot sizes (a PNG's width and height, from its IHDR chunk).
	for (const resolution of ['1x', 'full', undefined]) {
		const factor = resolution === 'full' ? scale : 1;
		try {
			const data = await native('screenshot', { format: 'png', quality: 92, resolution });
			const bytes = Uint8Array.from(atob(data.slice(0, 64)), (c) => c.charCodeAt(0));
			const u32 = (i) => ((bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]) >>> 0;
			near(u32(16), even(width, factor), 2, `the ${resolution ?? 'default'} screenshot's width`);
			near(u32(20), even(height, factor), 2, `the ${resolution ?? 'default'} screenshot's height`);
		} catch (e) {
			expect(false, `the ${resolution ?? 'default'} screenshot: ${e.message ?? e}`);
		}
	}

	// 2. OCR Mode: a popup on 手, then the window goes off screen.
	const char = await until('手 read', () => [...document.querySelectorAll('#ocr-text .ocr-char')].find((c) => c.textContent === '手'), 30000)
		.catch(() => null);
	if (expect(char, '手 read from the window')) {
		await native('debugMouse', center(char.getBoundingClientRect()));
		expect(await until('the popup', popupVisible, 10000).catch(() => false), 'a popup on the OCR text');
		window.__macpopupOcr({ type: 'window', visible: false });
		await wait(300);
		expect(!popupVisible(), 'the popup closed once the window is hidden');
		await native('debugMouse', { x: 5, y: 5 });
	}

	// 3. The Floating Window: a line, a popup on its 手, then a space change.
	await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ocrMode: false }) });
	await wait(1000);
	window.__macpopupClipboard('上から見ると手の中に生き物が出た。');
	const line = await lineWith('手の中', 5000);
	await native('debugMouse', center(rangeOf(line, '手').getBoundingClientRect()));
	expect(await until('the popup', popupVisible, 10000).catch(() => false), 'a popup on the line');
	window.__macpopupSpaceChanged();
	await wait(300);
	expect(!popupVisible(), 'the popup closed on a space change');
});
