// Switching to another app while the controller has focus (Gamepads.appActivated → __macpopupReleaseForGame): with
// SwitchTestA in front, A gives the controller focus (the popup on the line's start, 明日) and the popup stays open 3 s
// later; once SwitchTestB is brought to the front (System Events, as clicking it would), the popup closes and the focus
// ends, so the direction pad does nothing; A gives the focus back (the popup on 明日 again) and A once more ends it
// (gamepad-switch-driver.py). The controller's presses are the page's (__macpopupGamepad), not a real controller's.
// Opens two test windows that come to the front and brings each to the front.
// interactive
// mock: MOCK_RUN_FILES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// beside: w=$("$HARNESS/tools/build.sh" "$REPO/Tests/App/picker/plainwin.swift"); "$w" SwitchTestB 400 300 & sleep 1; "$w" SwitchTestA 200 200 & wait
// driver: python3 -I "$REPO/Tests/App/gamepad/gamepad-switch-driver.py"
// timeout: 90

test('overlay', async () => {
	await lineWith('明日も晴れるといいね');
	await wait(500);
	const popupWord = async () => {
		await until('the popup', () => popupVisible() && boxText('scan'), 3000).catch(() => {});
		return popupVisible() ? boxText('scan') : '';
	};
	const nothing = (when) => {
		equal(boxText('scan'), '', `${when}: the highlight`);
		equal(boxText('gamepad'), '', `${when}: the controller's cursor`);
		equal(popupVisible(), false, `${when}: the popup is open`);
	};

	log('want A in front');
	equal(await driverSaid('front ', 60000), 'front A', 'SwitchTestA in front before the controller takes focus');
	await gamepadPress(['Button A'], { after: 100 });
	equal(await popupWord(), '明日', 'A (controller focus): the popup\'s word');
	await wait(3000);
	equal(popupVisible(), true, '3 s later, SwitchTestA still in front: the popup is open');
	log('switch now');
	equal(await driverSaid('switched', 30000), 'switched to B', 'SwitchTestB brought to the front');
	await wait(1000);
	nothing('SwitchTestB in front');
	await gamepadPress(['Direction Pad Right'], { after: 1500 });
	nothing('right after the switch (no focus)');
	await gamepadPress(['Button A'], { after: 100 });
	equal(await popupWord(), '明日', 'A again (focus again): the popup\'s word');
	await gamepadPress(['Button A']);
	nothing('A (focus off)');
});
