// Highlight boxes after a resize (lib/highlight-boxes.js): hovers 晴れ on a long line's second row, then, in an
// animation frame, changes the text box's width (the word moves as the line wraps again) and compares the scan boxes
// with the word's rects at the start of the next frame (what the resized frame painted) and of the one after: the
// boxes are drawn from the resize observer, so they're where the word is in the resized frame already (0 px off; with
// a redraw a frame later they were 44–244 px off).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "scanModifier": "none", "hidePopupOnCursorExit": false, "autoHideResults": false, "boxRect": {"x": 300, "y": 700, "width": 1030, "height": 362}}
// timeout: 60

test('overlay', async () => {
	const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
	await lineWith('明日も晴れる');
	const text = '今日はとても寒いですね駅まで歩いて行きました彼は何も言わなかったもう少し待ってくださいそれは秘密です明日も晴れるといいね本当にそう思うの';
	window.__macpopupClipboard(text);
	const line = await lineWith('本当にそう思うの');
	await wait(1500);
	const word = rangeOf(line, '晴れ');
	const first = word.getClientRects()[0];
	expect(first.top > line.getBoundingClientRect().top + first.height / 2, `晴れ is on the line's second row or later (${Math.round(first.top)}, the line's top ${Math.round(line.getBoundingClientRect().top)})`);
	await native('debugMouse', { x: first.left + 4, y: first.top + first.height / 2 });
	await until('the scan boxes', () => document.querySelector('#box-highlights > .scan'), 5000);
	await wait(500);
	// How far the scan boxes are from the word's rects (the largest corner difference), or null without boxes.
	const offset = () => {
		const boxes = [...document.querySelectorAll('#box-highlights > .scan')].map((b) => b.getBoundingClientRect());
		if (boxes.length === 0) return null;
		const rects = [...word.getClientRects()].filter((r) => r.width > 0);
		let worst = 0;
		for (const r of rects) {
			const closest = Math.min(...boxes.map((b) => Math.max(Math.abs(b.left - r.left), Math.abs(b.top - r.top))));
			worst = Math.max(worst, closest);
		}
		return Math.round(worst);
	};
	equal(boxText('scan'), '晴れ', 'the highlight');
	equal(offset(), 0, 'before the resize: px off');
	const box = document.querySelector('#box');
	const start = box.getBoundingClientRect().width;
	let moved = 0;
	for (const width of [start - 260, start - 120, start + 40, start]) {
		const before = word.getClientRects()[0];
		let painted, next;
		await new Promise((resolve) => requestAnimationFrame(() => {
			box.style.width = `${width}px`;
			requestAnimationFrame(() => {
				painted = offset();
				requestAnimationFrame(() => {
					next = offset();
					resolve();
				});
			});
		}));
		const r = word.getClientRects()[0];
		if (Math.round(r.left) !== Math.round(before.left) || Math.round(r.top) !== Math.round(before.top)) moved++;
		equal(painted, 0, `width ${Math.round(width)} (晴れ at ${Math.round(r.left)},${Math.round(r.top)}): px off in the resized frame`);
		equal(next, 0, `width ${Math.round(width)}: px off a frame later`);
		await frame();
		await wait(500);
	}
	expect(moved >= 3, `the word moved in ${moved} of 4 resizes`);
});
