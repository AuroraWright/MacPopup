// Tooltips for titles in the popup (lib/tooltip.js, standing in for AppKit's): resting on the play button shows its
// title after 1.5 s (not at 1 s), 19 px below the pointer (above it when there's no room), in the system appearance's
// colors; moving to another element with a title while one shows takes 0.25 s; a press hides it until the pointer moves
// to another element; the audio menu's "Use as audio for Anki card" gets one above the menu; the text box's drag handle
// gets the overlay's own; moving away hides them.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "audioEnabled": true, "audioVolume": 0, "audioFallbackSound": "none", "audioDefaultSources": false, "audioSources": [{"type": "custom", "url": "http://127.0.0.1:59879/tip/{term}"}]}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const frame = () => document.querySelector('iframe.yomitan-popup');
	const doc = () => popupDocument();
	const button = await until('the play button', () => doc()?.querySelector('.entry .action-button[data-action=play-audio]'));
	await wait(2000);
	const tipIn = (d) => d.querySelector('.macpopup-tooltip');
	const tip = () => tipIn(doc());
	const shown = (node = tip()) => (node && !node.hidden ? node.textContent : null);
	// Points at an element in the popup; returns the point in the popup's coordinates.
	const moveTo = async (element) => {
		const f = frame().getBoundingClientRect();
		const point = center(element.getBoundingClientRect());
		await native('debugMouse', { x: f.left + point.x, y: f.top + point.y });
		return point;
	};

	const point = await moveTo(button);
	await wait(1000);
	equal(shown(), null, 'the play button\'s tooltip after 1 s');
	await wait(700);
	equal(shown(), button.title, 'the play button\'s tooltip after 1.7 s');
	const r = tip().getBoundingClientRect();
	const { clientWidth, clientHeight } = doc().documentElement;
	const left = Math.round(Math.max(4, Math.min(point.x, clientWidth - r.width - 4)));
	const top = Math.round(point.y + 19 + r.height <= clientHeight - 4 ? point.y + 19 : Math.max(4, point.y - r.height - 6));
	expect(Math.abs(r.left - left) <= 1 && Math.abs(r.top - top) <= 1,
		`the tooltip at ${Math.round(r.left)},${Math.round(r.top)} for the pointer at ${Math.round(point.x)},${Math.round(point.y)} (expected ${left},${top})`);
	const dark = frame().contentWindow.matchMedia('(prefers-color-scheme: dark)').matches;
	equal(getComputedStyle(tip()).backgroundColor, dark ? 'rgba(50, 52, 54, 0.82)' : 'rgba(226, 227, 228, 0.91)',
		`the tooltip's background in the ${dark ? 'dark' : 'light'} appearance`);

	// Another element with a title in view.
	const other = [...doc().querySelectorAll('[title]')].find((element) => {
		const rect = element.getBoundingClientRect();
		return element !== button && element.title && rect.width > 0 && rect.top >= 0 && rect.bottom <= clientHeight;
	});
	expect(other, `another element with a title: ${other?.tagName}.${other?.className} ${JSON.stringify(other?.title)}`);
	await moveTo(other);
	await wait(100);
	equal(shown(), null, 'the other element\'s tooltip after 0.1 s');
	await wait(300);
	equal(shown(), other.title, 'the other element\'s tooltip after 0.4 s');
	doc().dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
	await wait(1500);
	equal(shown(), null, 'the tooltip 1.5 s after a press');
	await moveTo(button);
	await wait(1700);
	equal(shown(), button.title, 'the play button\'s tooltip again after 1.7 s');

	// The audio menu's "Use as audio for Anki card", over the menu.
	button.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2 }));
	await wait(300);
	const primary = await until('the menu\'s "Use as audio for Anki card"', () => doc().querySelector('.popup-menu-item-set-primary-audio-button:not([hidden])'));
	await moveTo(primary);
	await wait(1700);
	equal(shown(), 'Use as audio for Anki card', 'the menu button\'s tooltip');
	const menuZ = Number(getComputedStyle(doc().querySelector('.popup-menu-container')).zIndex) || 0;
	const tipZ = Number(getComputedStyle(tip()).zIndex);
	expect(tipZ > menuZ, `the tooltip (z-index ${tipZ}) is above the menu (z-index ${menuZ})`);
	doc().querySelector('.popup-menu-container')?.click();
	await wait(300);

	// The text box's drag handle (the overlay's own tooltip).
	const handle = document.querySelector('#drag-handle').getBoundingClientRect();
	await native('debugMouse', { x: handle.left + 20, y: handle.top + handle.height / 2 });
	await wait(1700);
	equal(shown(tipIn(document)), 'Drag to move', 'the drag handle\'s tooltip');
	await native('debugMouse', { x: 2, y: 2 });
	await wait(200);
	equal([shown(), shown(tipIn(document))], [null, null], 'the tooltips with the pointer away');
});
