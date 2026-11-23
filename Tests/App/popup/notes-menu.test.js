// A word already added twice: "View added note" offers both notes on a right-click (instead of the browser's menu) and
// opens the one picked in Anki; a Shift-click on the play button opens the audio menu.
// mock: MOCK_NOTES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "ankiEnabled": true, "checkForDuplicates": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const doc = () => popupDocument();
	const button = await until('the View added note button', () => doc()?.querySelector('.entry .action-button[data-action=view-note]'));
	equal(button.dataset.noteIds, '111 222', 'the button\'s notes');

	const menuItems = (selector) => [...doc().querySelectorAll(`${selector} .popup-menu-item`)].map((item) => item.textContent.trim());
	const event = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2 });
	button.dispatchEvent(event);
	await wait(300);
	expect(event.defaultPrevented, 'the right-click doesn\'t open the browser\'s menu');
	const items = menuItems('.view-note-button-popup-menu');
	equal(items.length, 2, `the notes menu's items (${items.join(' | ')})`);

	[...doc().querySelectorAll('.view-note-button-popup-menu .popup-menu-item')][1].click();
	await wait(1000);
	equal(doc().querySelectorAll('.popup-menu-container').length, 0, 'menus open after picking');
	const opened = (await mockLog()).filter((l) => /^anki \d+ gui(Browse|EditNote) /.test(l));
	expect(opened.length > 0 && opened.every((l) => l.includes('222') && !l.includes('111')),
		`Anki is asked to show note 222 only: ${opened.map((l) => l.replace(/^anki \d+ /, '')).join('; ')}`);

	const play = doc().querySelector('.entry .action-button[data-action=play-audio]');
	play.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, shiftKey: true }));
	await wait(300);
	expect(doc().querySelectorAll('.popup-menu-container').length === 1, 'Shift-click opens the audio menu');
});
