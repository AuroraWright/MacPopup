// The play button's audio menu, as Yomitan's DisplayAudio: with two Custom URL sources on the mock's audio server,
// autoplay asks the first source only and plays it (the button's title says "From source 1"); opening the menu (a
// right-click) asks no source by itself, and lists the first as working and the second as not tried yet; playing the
// second from the menu asks it, uses it for Anki cards, and the menu then shows both working, with a plus on the button
// and the button's title as it was (as in Yomitan).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "audioEnabled": true, "audioAutoPlay": true, "audioVolume": 0, "audioFallbackSound": "none", "audioDefaultSources": false, "audioSources": [{"type": "custom", "url": "http://127.0.0.1:59879/first/{term}"}, {"type": "custom", "url": "http://127.0.0.1:59879/second/{term}"}]}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const frame = () => document.querySelector('iframe.yomitan-popup');
	const doc = () => popupDocument();
	const button = await until('the play button', () => doc()?.querySelector('.entry .action-button[data-action=play-audio]'));
	const audioRequests = async () => (await mockLog()).filter((l) => l.startsWith('audio ')).map((l) => l.split(' ')[2]);
	await until('the autoplay request', async () => (await audioRequests()).length > 0);
	await wait(1000);
	const afterAutoplay = await audioRequests();
	equal(afterAutoplay.length, 1, 'audio requests after autoplay');
	expect(afterAutoplay[0]?.startsWith('/first/'), `autoplay asks the first source: ${afterAutoplay[0]}`);
	const badge = button.querySelector('.action-button-badge');
	expect(badge.hidden, 'no badge with one audio known');
	expect(button.title.endsWith('\nFrom source 1: Custom URL'), `the button's title after autoplay: ${JSON.stringify(button.title)}`);

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
	equal(items(), ['Custom URL 1 [true]', 'Custom URL 2 [null]'], 'the menu\'s items');
	await wait(2000);
	equal(items(), ['Custom URL 1 [true]', 'Custom URL 2 [null]'], 'the menu\'s items 2 s later');
	equal((await audioRequests()).length, 1, 'audio requests after opening the menu');

	// Marked, to see that playing from the menu leaves it (both sources are called Custom URL).
	button.title += ' (marked)';
	const markedTitle = button.title;
	await pointAtButton();
	groups().at(-1).querySelector('.popup-menu-item-audio-button').click();
	await wait(2000);
	const afterPlay = await audioRequests();
	equal(afterPlay.length, 2, 'audio requests after playing the menu\'s last item');
	expect(afterPlay[1]?.startsWith('/second/'), `the menu's last item asks the second source: ${afterPlay[1]}`);
	equal(doc().querySelectorAll('.popup-menu-container').length, 0, 'menus open after playing an item');

	await openMenu();
	equal(items(), ['Custom URL 1 [true]', 'Custom URL 2 [true]'], 'the menu\'s items after playing');
	equal(groups().map((group) => group.dataset.isPrimaryCardAudio), ['false', 'true'], 'the audio used for Anki cards');
	expect(!badge.hidden && badge.dataset.icon === 'plus-thick', `the badge with two audio known: ${badge.hidden ? 'hidden' : badge.dataset.icon}`);
	equal(button.title, markedTitle, 'the button\'s title after playing from the menu');
});
