// OwOtan's popup fixes, with Yomitan's own styling (no custom popup CSS) and collapsed definitions: a block wider than
// the popup in a collapsible definition leaves its expand button inside the definition (bdf2c842: the content's
// min-width 0; with min-width auto, as before it, the button is pushed out); and the audio menu is placed at whole
// pixels (9c2a6dda).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "definitionsCollapsible": "collapsed", "audioEnabled": true, "customPopupCss": ""}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const doc = () => popupDocument();
	const inner = await until('a collapsible definition', () => doc()?.querySelector('.entry .definition-item-inner.collapsible'));
	const content = inner.querySelector('.definition-item-content');
	const wide = doc().createElement('div');
	wide.style.cssText = `width: ${doc().documentElement.clientWidth + 100}px; height: 20px; background: gray;`;
	content.prepend(wide);
	await wait(300);
	const style = (element) => element.ownerDocument.defaultView.getComputedStyle(element);
	equal(style(content).minWidth, '0px', 'the definition content\'s min-width');
	const placement = () => {
		const item = inner.closest('.definition-item').getBoundingClientRect();
		const button = inner.querySelector('.expansion-button').getBoundingClientRect();
		const inside = button.left >= item.left - 1 && button.right <= item.right + 1;
		return { inside, text: `definition ${Math.round(item.left)}–${Math.round(item.right)}, expand button ${Math.round(button.left)}–${Math.round(button.right)}` };
	};
	const built = placement();
	expect(built.inside, `the expand button is inside the definition: ${built.text}`);
	content.style.minWidth = 'auto';
	await wait(100);
	const before = placement();
	expect(!before.inside, `with min-width auto (before bdf2c842) it's pushed out: ${before.text}`);
	content.style.minWidth = '';

	const play = doc().querySelector('.entry .action-button[data-action=play-audio]');
	play.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2 }));
	await wait(500);
	const menus = [...doc().querySelectorAll('#popup-menus .popup-menu')];
	equal(menus.length, 1, 'audio menus open');
	const { left, top } = menus.at(-1)?.style ?? {};
	expect(/^-?\d+px$/.test(left) && /^-?\d+px$/.test(top), `the audio menu is at whole pixels: left ${left} top ${top}`);
});
