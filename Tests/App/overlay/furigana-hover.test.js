// The scanned word's highlight box on furigana text with the real pointer (lib/highlight-boxes.js measures the ruby's
// base text, leaving out the furigana): with "Show furigana" and MOCK_TOKENIZE (one token a character, よみ over each
// kanji), a long line wraps in the text box; the pointer goes along 晴's row onto 晴: the popup opens on 晴れ, with a box
// over 晴 and one over れ, each exactly on its characters, and none over the furigana above.
// Moves the real pointer, over the test instance's text box only (put back afterwards).
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_TOKENIZE=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "showFurigana": true, "scanModifier": "none", "hidePopupOnCursorExit": false, "autoHideResults": false, "boxRect": {"x": 300, "y": 450, "width": 1030, "height": 362}}
// driver: python3 -I "$HARNESS/tools/pointer.py"
// timeout: 90

test('overlay', async () => {
	// A line's text without its furigana.
	const baseText = (p) => {
		const copy = p.cloneNode(true);
		copy.querySelectorAll('rt, rp').forEach((e) => e.remove());
		return copy.textContent;
	};
	const lineWithText = (text) => until(`a line with ${text}`, () => [...document.querySelectorAll('#lines p[data-line-id]')]
		.find((p) => baseText(p).includes(text)), 30000);
	await lineWithText('明日も晴れる');
	window.__macpopupClipboard('今日はとても寒いですね、駅まで歩いて行きました、彼は何も言わなかった、明後日もきっと晴れるといいね');
	const ruby = await until("furigana over the long line's 晴", async () => [...(await lineWithText('明後日もきっと')).querySelectorAll('ruby')]
		.find((el) => el.firstChild?.data === '晴'), 15000);
	await wait(1000);
	equal(ruby.querySelector('rt')?.textContent, 'よみ', "晴's furigana");
	const base = document.createRange();
	base.selectNodeContents(ruby.firstChild);
	const rect = base.getBoundingClientRect();
	const rt = ruby.querySelector('rt').getBoundingClientRect();
	// The next token (one a character): れ.
	const after = ruby.closest('span.token')?.nextElementSibling;
	equal(after?.textContent, 'れ', 'the token after 晴');
	const re = rangeOf(after, 'れ').getBoundingClientRect();
	const box = document.querySelector('#box').getBoundingClientRect();
	const r = (b) => `${Math.round(b.left)},${Math.round(b.top)} ${Math.round(b.width)}x${Math.round(b.height)}`;
	log(`晴 ${r(rect)}, its furigana ${r(rt)}, れ ${r(re)}, box ${r(box)}`);
	expect(rect.top >= box.top && rect.bottom <= box.bottom, '晴 shows in the text box');

	const onWord = center(rect);
	if (!await pointerMove({ x: box.left + 30, y: onWord.y }, onWord, 300)) return;
	await until('the popup on 晴れ', () => popupVisible() && boxText('scan') === '晴れ', 10000).catch(() => {});
	await wait(800);
	const boxes = [...document.querySelectorAll('#box-highlights > .scan')].map((b) => b.getBoundingClientRect());
	log(`scan boxes ${boxes.map(r).join(' | ')}`);
	equal(popupVisible(), true, 'the popup is open');
	equal(boxText('scan'), '晴れ', 'the highlight');
	equal(boxes.length, 2, 'scan boxes (晴 in its ruby, れ after it)');
	const on = (b, c) => Math.max(Math.abs(b.left - c.left), Math.abs(b.top - c.top), Math.abs(b.right - c.right), Math.abs(b.bottom - c.bottom)) <= 1;
	expect(boxes.some((b) => on(b, rect)), `a box exactly over 晴 (${r(rect)})`);
	expect(boxes.some((b) => on(b, re)), `a box exactly over れ (${r(re)})`);
	expect(boxes.every((b) => b.top >= rt.bottom - 1 || b.bottom <= rt.top || b.right <= rt.left || b.left >= rt.right),
		`no box over the furigana (${r(rt)})`);
});
