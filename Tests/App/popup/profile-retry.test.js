// The Yomitan profile when its first request fails (MOCK_PROFILE=1 MOCK_PROFILE_FAIL=2: the first two displayOptions
// are answered 503, the overlay's and the host's status check at launch, which come in either order): the first popup
// shows MacPopup's own settings (font size 14), and since a failure isn't taken as an older Yomitan (only a 400 is), the
// profile is asked again once the reading is 5 s old, at the next lookup, whose popup then gets the profile's font size
// (21) and theme.
// mock: MOCK_PROFILE=1 MOCK_PROFILE_FAIL=2
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "autoHideResults": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	const word = center(rangeOf(line, '晴').getBoundingClientRect());
	const visible = () => [...document.querySelectorAll('iframe.yomitan-popup')].some((frame) => getComputedStyle(frame).visibility === 'visible');
	const fontSize = () => popupDocument()?.documentElement.style.fontSize;
	await native('debugMouse', word);
	await until('the first popup', () => popupDocument()?.querySelector('.entry'));
	await wait(500);
	equal(fontSize(), '14px', 'the first popup\'s font size');
	const first = await mockLog();
	equal(first.filter((l) => l.startsWith('yomitan-503 displayOptions')).length, 2, 'displayOptions requests failed');
	equal(first.some((l) => l.startsWith('yomitan-400')), false, 'answers 400');

	await native('debugMouse', { x: 5, y: 5 });
	await until('the popup hidden', () => !visible(), 3000);
	await wait(5500);
	await native('debugMouse', word);
	await until('the second popup with the profile\'s font size', () => visible() && fontSize() === '21px', 5000).catch(() => {});
	equal([fontSize(), popupDocument()?.documentElement.dataset.theme], ['21px', 'dark'], 'the second popup\'s font size and theme');
	const asked = (await mockLog()).filter((l) => / displayOptions$/.test(l) && l.startsWith('yomitan '));
	expect(asked.length >= 2, `displayOptions asked again: ${asked.length} requests`);
});
