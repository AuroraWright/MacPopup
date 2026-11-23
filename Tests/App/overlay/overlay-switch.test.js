// Settings → General → Overlay switch buttons (controller buttons X + Y): pressing X + Y switches to the OCR overlay
// (ocrMode on), X alone doesn't switch, Y + X (the same buttons in another order) switches back. The debug log has each
// switch, from the controller. (The keyboard shortcut isn't tested: key presses posted from a test don't reach global
// hotkeys; it's handled as the other global shortcuts are, by HotkeyController.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": false, "ocrShowBoxes": true, "ocrCloudEngine": "none", "overlaySwitchButtons": ["Button X", "Button Y"], "overlayHideButtons": [], "gamepadScanButtons": []}
// timeout: 60

test('overlay', async () => {
	const ocrMode = async () => JSON.parse(await native('getSettings')).ocrMode;
	await wait(1500);
	equal(await ocrMode(), false, 'at the start: ocrMode');
	await gamepadPress(['Button X', 'Button Y']);
	equal(await ocrMode(), true, 'after X + Y: ocrMode');
	await gamepadPress(['Button X']);
	equal(await ocrMode(), true, 'after X alone: ocrMode');
	await gamepadPress(['Button Y', 'Button X']);
	equal(await ocrMode(), false, 'after Y + X: ocrMode');
	const switches = (await debugRecords()).filter((r) => r.event === 'overlay switch').map(({ from, ocrMode }) => ({ from, ocrMode }));
	equal(switches, [{ from: 'controller', ocrMode: true }, { from: 'controller', ocrMode: false }], 'the debug log\'s switches');
});
