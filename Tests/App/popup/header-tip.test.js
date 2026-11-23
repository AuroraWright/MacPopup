// Tooltips on the text box's header buttons (lib/tooltip.js): resting on Settings shows "Settings" after 1.5 s (not
// at 1 s), at the pointer and 19 px below it (above it when there's no room); moving to Hide, then Pause, shows theirs
// after 0.25 s; moving away hides it. The old instant tip (#header-tip) is gone.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true}

test('overlay', async () => {
	await lineWith('明日も晴れる');
	equal(document.querySelector('#header-tip'), null, 'the old tip element');
	const tip = () => document.querySelector('.macpopup-tooltip');
	const shown = () => (tip() && !tip().hidden ? tip().textContent : null);
	const at = async (id) => {
		const point = center(document.querySelector(id).getBoundingClientRect());
		await native('debugMouse', point);
		return point;
	};
	// Onto the box first, so its header shows.
	await native('debugMouse', center(document.querySelector('#box').getBoundingClientRect()));
	await wait(500);
	const p = await at('#settings-button');
	await wait(1000);
	equal(shown(), null, 'Settings\' tooltip after 1 s');
	await wait(700);
	equal(shown(), 'Settings', 'Settings\' tooltip after 1.7 s');
	const r = tip().getBoundingClientRect();
	const { clientWidth, clientHeight } = document.documentElement;
	const left = Math.round(Math.max(4, Math.min(p.x, clientWidth - r.width - 4)));
	const top = Math.round(p.y + 19 + r.height <= clientHeight - 4 ? p.y + 19 : Math.max(4, p.y - r.height - 6));
	expect(Math.abs(r.left - left) <= 1 && Math.abs(r.top - top) <= 1,
		`the tooltip at ${Math.round(r.left - p.x)}, ${Math.round(r.top - p.y)} from the pointer (expected ${Math.round(left - p.x)}, ${Math.round(top - p.y)})`);
	await at('#hide-button');
	await wait(300);
	equal(shown(), 'Hide', 'Hide\'s tooltip after 0.3 s');
	await at('#pause-button');
	await wait(300);
	equal(shown(), 'Pause', 'Pause\'s tooltip after 0.3 s');
	await native('debugMouse', { x: 2, y: 2 });
	await wait(200);
	equal(shown(), null, 'the tooltip with the pointer away');
});
