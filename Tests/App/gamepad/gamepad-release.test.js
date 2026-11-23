// Before Game Sentence Audio records (and when the overlays hide, or another app comes to the front),
// __macpopupReleaseForGame closes the popups and ends the controller's focus: then the direction pad does nothing,
// and A gives the focus back (the popup opening on the line's start again), and A once more ends it.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "gamepadScanButtons": ["Button A"], "gamepadPopupDelay": 1000, "scanResolution": "character", "gamePause": false}
// timeout: 60

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

	await gamepadPress(['Button A'], { after: 100 });
	equal(await popupWord(), '明日', 'A (controller focus): the popup\'s word');
	window.__macpopupReleaseForGame();
	await wait(500);
	nothing('released for the game');
	await gamepadPress(['Direction Pad Right'], { after: 1500 });
	nothing('right after the release (no focus)');
	await gamepadPress(['Button A'], { after: 100 });
	equal(await popupWord(), '明日', 'A again (focus again): the popup\'s word');
	await gamepadPress(['Button A']);
	nothing('A (focus off)');
});
