// The window picker started from the OCR window (RaiseTestA, brought to the front over RaiseTestB) goes back to choosing
// the window when another app comes to the front: with RaiseTestB activated (System Events), its buttons are Cancel
// and Whole Screen again; Escape still closes it, and RaiseTestB doesn't get the key (picker-driver.py).
// Opens two test windows that come to the front, brings one to the front and presses Escape (only while one of them or
// the test instance is in front).
// interactive
// mock: MOCK_RUN_FILES=1
// setup: mkdir -p "$RUN/picker"
// env: MACPOPUP_DEBUG_PICKER_DIR=$RUN/picker
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "plainwin", "title": "RaiseTestA"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrShowBoxes": true}
// beside: w=$("$HARNESS/tools/build.sh" "$REPO/Tests/App/picker/plainwin.swift"); "$w" RaiseTestA 200 200 & sleep 1; "$w" RaiseTestB 300 250 & wait
// driver: python3 -I "$REPO/Tests/App/picker/picker-driver.py" switch
// timeout: 90

test('overlay', async () => {
	await windowStep('started RaiseTestB', 30000);
	await wait(2500);
	await native('ocr', { action: 'select' });
	log('select');
	await driverSaid('finished', 60000);
	const { ownerName, title } = JSON.parse(await native('getSettings')).ocrWindow ?? {};
	equal([ownerName, title], ['plainwin', 'RaiseTestA'], 'the OCR window after the picker was cancelled');
});
