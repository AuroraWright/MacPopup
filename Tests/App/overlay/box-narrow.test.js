// The text box saved narrower than its buttons (80 px) is shown wide enough for them, 4 px on each side (they sit
// above its top right corner), and a message (toast) longer than the box is wide wraps inside it (it was cut off by
// the box's edges); a short one stays on one line (30 px tall).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "boxRect": {"x": 600, "y": 700, "width": 80, "height": 200}}

test('overlay', async () => {
	await lineWith('明日も晴れるといいね');
	await wait(1000);
	const box = document.querySelector('#box').getBoundingClientRect();
	const buttons = document.querySelector('#box-buttons').getBoundingClientRect();
	log(`box ${Math.round(box.left)} ${Math.round(box.width)}, buttons ${Math.round(buttons.left)} ${Math.round(buttons.width)}`);
	expect(box.width >= buttons.width + 8, `the box (${box.width}) fits its buttons (${buttons.width}) + 8`);
	expect(buttons.left >= box.left + 3.5 && buttons.right <= box.right - 3.5, 'the buttons are within the box, 4 px from each side');
	window.__macpopupToast('Couldn’t add the card: this message is a lot longer than the text box is wide, so it has to wrap');
	await wait(300);
	const toast = document.querySelector('#toast').getBoundingClientRect();
	log(`toast ${Math.round(toast.left)} ${Math.round(toast.top)} ${Math.round(toast.width)} ${Math.round(toast.height)}`);
	expect(toast.left >= box.left && toast.right <= box.right, `the toast (${Math.round(toast.left)}–${Math.round(toast.right)}) is within the box (${Math.round(box.left)}–${Math.round(box.right)})`);
	expect(toast.height > 30, `it wraps: ${Math.round(toast.height)} px tall`);
	await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), boxRect: { x: 600, y: 700, width: 900, height: 200 } }) });
	await wait(500);
	window.__macpopupToast('A short message');
	await wait(300);
	const short = document.querySelector('#toast').getBoundingClientRect();
	expect(short.height <= 30, `a short one stays on one line: ${Math.round(short.height)} px tall, ${Math.round(short.width)} wide`);
});
