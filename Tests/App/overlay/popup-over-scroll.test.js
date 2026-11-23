// The scanned word's highlight box with the real pointer while the text box scrolls (lib/highlight-boxes.js: the boxes
// are in the scrolled element): 15 short lines, the last one 明後日もきっと晴れるといいね; the pointer goes onto 晴 (the
// popup opens on 晴れ with one box over it), then into the popup, and a line is added: the box scrolls to the end, the
// popup stays open and the box stays exactly on the word where it moved (half a second later).
// Moves the real pointer, over the test instance's text box and popup only (put back afterwards).
// interactive
// mock: MOCK_RUN_FILES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "scanModifier": "none", "hidePopupOnCursorExit": false, "autoHideResults": false, "boxRect": {"x": 300, "y": 450, "width": 1030, "height": 362}}
// driver: python3 -I "$HARNESS/tools/pointer.py"
// timeout: 90

test('overlay', async () => {
	await lineWith('明日も晴れる');
	const sentences = ['今日はとても寒いですね', '駅まで歩いて行きました', '彼は何も言わなかった', 'もう少し待ってください', '本当にそう思うの？', 'それは秘密です'];
	for (let i = 0; i < 14; i++) {
		window.__macpopupClipboard(`${sentences[i % sentences.length]}${i}`);
		await wait(150);
	}
	window.__macpopupClipboard('明後日もきっと晴れるといいね');
	const line = await lineWith('明後日もきっと');
	await wait(1500);
	const lines = document.querySelector('#lines');
	const word = rangeOf(line, '晴れ');
	const rect = rangeOf(line, '晴').getBoundingClientRect();
	const box = document.querySelector('#box').getBoundingClientRect();
	const r = (b) => `${Math.round(b.left)},${Math.round(b.top)} ${Math.round(b.width)}x${Math.round(b.height)}`;
	log(`晴 ${r(rect)}, box ${r(box)}, lines scrolled ${lines.scrollTop} of ${lines.scrollHeight - lines.clientHeight}`);
	expect(lines.scrollTop > 0, `the text box is scrolled (${lines.scrollTop})`);
	expect(rect.top >= box.top && rect.bottom <= box.bottom, '晴 shows in the text box');
	const offset = () => {
		const boxes = [...document.querySelectorAll('#box-highlights > .scan')].map((b) => b.getBoundingClientRect());
		if (boxes.length === 0) return null;
		let worst = 0;
		for (const w of [...word.getClientRects()].filter((w) => w.width > 0)) {
			worst = Math.max(worst, Math.min(...boxes.map((b) => Math.max(Math.abs(b.left - w.left), Math.abs(b.top - w.top),
				Math.abs(b.bottom - w.bottom)))));
		}
		return Math.round(worst);
	};
	const scanBoxes = () => document.querySelectorAll('#box-highlights > .scan').length;

	const onWord = center(rect);
	if (!await pointerMove({ x: box.left + 30, y: onWord.y }, onWord, 300)) return;
	await until('the popup on 晴れ', () => popupVisible() && boxText('scan') === '晴れ', 10000).catch(() => {});
	await wait(800);
	equal(boxText('scan'), '晴れ', 'the pointer on 晴: the highlight');
	equal(scanBoxes(), 1, 'the pointer on 晴: scan boxes');
	equal(offset(), 0, 'the pointer on 晴: px between the box and the word');

	const p = [...document.querySelectorAll('iframe.yomitan-popup')].find((f) => f.style.visibility === 'visible').getBoundingClientRect();
	log(`popup ${r(p)}`);
	const x = Math.min(Math.max(onWord.x, p.left + 20), p.right - 20);
	const y = p.bottom <= rect.top + 2 ? p.bottom - 40 : p.top >= rect.bottom - 2 ? p.top + 40 : p.top + p.height / 2;
	if (!await pointerMove(onWord, { x, y }, 250)) return;
	await wait(1500);
	equal(popupVisible(), true, 'in the popup: the popup is open');
	equal(offset(), 0, 'in the popup: px between the box and the word');

	const before = { scroll: lines.scrollTop, top: word.getClientRects()[0].top };
	window.__macpopupClipboard('もう一つの行です');
	await wait(500);
	const after = { scroll: lines.scrollTop, top: word.getClientRects()[0].top };
	log(`line added: scrolled ${before.scroll} → ${after.scroll}, 晴れ's top ${Math.round(before.top)} → ${Math.round(after.top)}`);
	expect(after.scroll > before.scroll && after.top < before.top, 'the text box scrolled to the new line, moving the word up');
	equal(popupVisible(), true, 'line added: the popup is open');
	equal(boxText('scan'), '晴れ', 'line added: the highlight');
	equal(scanBoxes(), 1, 'line added: scan boxes');
	equal(offset(), 0, 'line added: px between the box and the word');
});
