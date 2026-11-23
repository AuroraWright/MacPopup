// The Overlay hide buttons (overlayHideButtons X + Y): each press hides the overlays or shows them again, as the menu
// bar's Hide Overlays; the switch buttons (B) still switch to the OCR overlay. The debug log's events: "overlay hide"
// visible false, then true, then "overlay switch" (ocrMode on), all from the controller. (The page's timers run about
// a second apart while the overlay is hidden.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": false, "ocrShowBoxes": true, "ocrCloudEngine": "none", "overlayHideButtons": ["Button X", "Button Y"], "overlaySwitchButtons": ["Button B"], "gamepadScanButtons": ["Button A"], "gamePause": false}
// timeout: 90

test('overlay', async () => {
	const events = async () => (await debugRecords()).filter((r) => r.event === 'overlay hide' || r.event === 'overlay switch')
		.map(({ time, type, ...rest }) => rest);
	await wait(1500);
	await gamepadPress(['Button X', 'Button Y']);
	await until('the first hide', async () => (await events()).length >= 1, 15000).catch(() => {});
	equal(await events(), [{ event: 'overlay hide', from: 'controller', visible: false }], 'pressed once: the events');
	await wait(1000);
	await gamepadPress(['Button X', 'Button Y']);
	await until('the second hide', async () => (await events()).length >= 2, 15000).catch(() => {});
	await wait(1000);
	await gamepadPress(['Button B']);
	await until('the switch', async () => (await events()).length >= 3, 15000).catch(() => {});
	equal(await events(), [
		{ event: 'overlay hide', from: 'controller', visible: false },
		{ event: 'overlay hide', from: 'controller', visible: true },
		{ event: 'overlay switch', from: 'controller', ocrMode: true },
	], 'the events');
	equal(JSON.parse(await native('getSettings')).ocrMode, true, 'after B: ocrMode');
	await wait(1500);
});
