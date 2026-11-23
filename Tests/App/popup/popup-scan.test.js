// A lookup inside the popup on a wrapped definition: scanning the first character on a definition's second row
// (Popup.scanAt) opens a nested popup and highlights the 2 characters matched (the mock matches 2) with one box on that
// row, starting at the character (not stretched over the row above, as WebKit's highlight of a wrapped row was).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const frame = () => document.querySelector('iframe.yomitan-popup');
	await until('the popup', () => frame() && frame().style.visibility !== 'hidden' && frame().offsetWidth > 0 && popupDocument()?.querySelector('.entry'));
	await wait(800);
	const doc = frame().contentDocument;
	const charRange = (node, i, length = 1) => {
		const range = doc.createRange();
		range.setStart(node, i);
		range.setEnd(node, i + length);
		return range;
	};
	// The first character on a definition's second row.
	const defs = doc.createTreeWalker(doc.querySelector('#dictionary-entries'), NodeFilter.SHOW_TEXT);
	let target = null;
	for (let node; !target && (node = defs.nextNode()); ) {
		if (node.data.length < 40) continue;
		const top = charRange(node, 0).getBoundingClientRect().top;
		for (let i = 1; i < node.data.length - 6 && !target; i++) {
			if (charRange(node, i).getBoundingClientRect().top > top + 5 && /\w/.test(node.data[i])) target = { node, i };
		}
	}
	if (!target) throw new Error('no wrapped definition');
	const t = charRange(target.node, target.i).getBoundingClientRect();
	const word = charRange(target.node, target.i, 2).getBoundingClientRect();
	const popups = () => [...document.querySelectorAll('iframe.yomitan-popup')].filter((f) => f.style.visibility !== 'hidden' && f.offsetWidth > 0).length;
	await frame().contentWindow.macpopupPopup.scanAt(t.left + t.width / 2, t.top + t.height / 2);
	await wait(1000);
	equal(popups(), 2, `popups shown after scanning "${target.node.data.slice(target.i, target.i + 12)}"`);
	const boxes = [...doc.querySelectorAll('#scan-highlights > div')].map((b) => b.getBoundingClientRect());
	const r = (rect) => `${Math.round(rect.left)},${Math.round(rect.top)} ${Math.round(rect.width)}x${Math.round(rect.height)}`;
	equal(boxes.length, 1, `highlight boxes (${boxes.map(r).join(' | ')})`);
	const box = boxes[0];
	expect(box && Math.abs(box.left - word.left) <= 2 && Math.abs(box.top - word.top) <= 2 && Math.abs(box.width - word.width) <= 2
		&& Math.abs(box.height - word.height) <= 3, `the box ${box && r(box)} covers the 2 characters at ${r(word)}`);
});
