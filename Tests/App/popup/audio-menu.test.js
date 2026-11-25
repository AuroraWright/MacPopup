// The play button's audio menu, badge and title, as Yomitan's DisplayAudio, with a Custom URL (JSON) source (the mock's
// list of three) and a Custom URL source. With autoplay off, the title is just "Play audio" and nothing is asked while
// nothing has played, also with the menu open (a right-click), which lists both sources as not tried yet; playing the
// second from the menu asks it only, uses it for Anki cards, and the title then names the first source, whichever the
// menu's was. With autoplay on, the next lookup's autoplay asks the first source only, plays its first audio, and the
// button shows a plus (more than one may play) and the title the first source.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "audioEnabled": true, "audioAutoPlay": false, "audioVolume": 0, "audioFallbackSound": "none", "audioDefaultSources": false, "audioSources": [{"type": "custom-json", "url": "http://127.0.0.1:59879/list/{term}"}, {"type": "custom", "url": "http://127.0.0.1:59879/first/{term}"}]}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const frame = () => document.querySelector('iframe.yomitan-popup');
	const doc = () => popupDocument();
	const playButton = () => doc()?.querySelector('.entry .action-button[data-action=play-audio]');
	let button = await until('the play button', playButton);
	await wait(1500);
	const audioRequests = async () => (await mockLog()).filter((l) => l.startsWith('audio')).map((l) => `${l.split(' ')[0]} ${decodeURIComponent(l.split(' ')[2])}`);
	const titleDefault = button.dataset.titleDefault;
	equal(titleDefault, 'Play audio', 'the button\'s own title');
	equal(button.title, titleDefault, 'the button\'s title with nothing played');
	const badge = () => button.querySelector('.action-button-badge');
	expect(badge().hidden, 'no badge with nothing played');
	equal(await audioRequests(), [], 'audio requests with nothing played');

	// The simulated pointer lasts 5 s (simulatedMouseUntil in OverlayController.swift): it's put on the play button
	// before each step, as when right-clicking it.
	const pointAtButton = () => {
		const f = frame().getBoundingClientRect();
		const r = button.getBoundingClientRect();
		return native('debugMouse', { x: f.left + r.left + r.width / 2, y: f.top + r.top + r.height / 2 });
	};
	const groups = () => [...doc().querySelectorAll('.popup-menu-item-group')];
	const items = () => groups().map((group) => `${group.querySelector('.popup-menu-item-label').textContent} [${group.dataset.valid}]`);
	const openMenu = async () => {
		await pointAtButton();
		button.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2 }));
		await wait(300);
	};
	await openMenu();
	equal(items(), ['Custom URL (JSON) [null]', 'Custom URL [null]'], 'the menu\'s items');
	await wait(2000);
	equal(items(), ['Custom URL (JSON) [null]', 'Custom URL [null]'], 'the menu\'s items 2 s later');
	equal(await audioRequests(), [], 'audio requests with the menu open');
	equal(button.title, titleDefault, 'the button\'s title with the menu open');

	await pointAtButton();
	groups().at(-1).querySelector('.popup-menu-item-audio-button').click();
	await wait(2000);
	const firstRequests = await audioRequests();
	equal(firstRequests.length, 1, 'audio requests after playing the menu\'s last item');
	expect(firstRequests[0]?.startsWith('audio /first/'), `the menu's last item asks the second source: ${firstRequests[0]}`);
	equal(doc().querySelectorAll('.popup-menu-container').length, 0, 'menus open after playing an item');
	equal(button.title, `${titleDefault}\nFrom source 1: Custom URL (JSON)`, 'the button\'s title after playing from the menu');

	await openMenu();
	equal(items(), ['Custom URL (JSON) [null]', 'Custom URL [true]'], 'the menu\'s items after playing');
	equal(groups().map((group) => group.dataset.isPrimaryCardAudio), ['false', 'true'], 'the audio used for Anki cards');
	expect(badge().hidden, 'no badge with one audio known');

	// The menu closed (a click beside it), then autoplay on, and another lookup.
	doc().querySelector('.popup-menu-container').click();
	await until('the menu closed', () => doc().querySelectorAll('.popup-menu-container').length === 0 || null);
	await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), audioAutoPlay: true }) });
	await native('debugMouse', center(rangeOf(line, '明').getBoundingClientRect()));
	// (The mock finds the same word, 晴れる, whose first source hasn't been asked yet.)
	button = await until('the next lookup\'s play button', () => {
		const next = playButton();
		return next && next !== button ? next : null;
	});
	await until('the autoplay', async () => (await audioRequests()).length > 1 || null);
	await wait(1000);
	const autoplayRequests = (await audioRequests()).slice(1);
	const term = autoplayRequests[0]?.split('/list/')[1];
	equal(autoplayRequests, [`audio-list /list/${term}`, `audio /second/${term}/0`], 'audio requests after autoplay (the first source only)');
	equal(button.title, `${titleDefault}\nFrom source 1: Custom URL (JSON)`, 'the button\'s title after autoplay');
	expect(!badge().hidden && badge().dataset.icon === 'plus-thick', `the badge after autoplay: ${badge().hidden ? 'hidden' : badge().dataset.icon}`);
});
