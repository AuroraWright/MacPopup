// The scanned word's highlight box with the real pointer (lib/highlight-boxes.js): one long line fills the text box,
// 晴 on a wrapped row; the pointer goes along that row onto 晴 (the popup opens on 晴れ, the mock's 2 characters, with
// one box exactly over them), then into the popup. The popup stays open and the box stays on the word, on its own row
// (WebKit's CSS highlight painted a band over the gap above a wrapped row once the line repainted, as its bullet faded
// with the pointer going onto the popup), 0.45, 0.85 and 2.35 s after.
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
	window.__macpopupClipboard(`${Array.from({ length: 12 }, (_, i) => sentences[i % sentences.length]).join('、')}、明後日もきっと晴れるといいね`);
	const line = await lineWith('明後日もきっと');
	await wait(1500);
	const word = rangeOf(line, '晴れ');
	const rect = rangeOf(line, '晴').getBoundingClientRect();
	const lineRect = line.getBoundingClientRect();
	const box = document.querySelector('#box').getBoundingClientRect();
	const r = (b) => `${Math.round(b.left)},${Math.round(b.top)} ${Math.round(b.width)}x${Math.round(b.height)}`;
	log(`line ${r(lineRect)}, 晴 ${r(rect)}, box ${r(box)}, lines scrolled ${document.querySelector('#lines').scrollTop}`);
	expect(rect.top > lineRect.top + rect.height, `晴 is on a wrapped row (${Math.round(rect.top)}, the line's top ${Math.round(lineRect.top)})`);
	expect(rect.top >= box.top && rect.bottom <= box.bottom, '晴 shows in the text box');
	// How far the scan boxes are from the word's rects (the largest corner difference), or null without boxes.
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
	equal(popupVisible(), true, 'the pointer on 晴: the popup is open');
	equal(scanBoxes(), 1, 'the pointer on 晴: scan boxes');
	equal(offset(), 0, 'the pointer on 晴: px between the box and the word');

	// Into the popup, from the word's side.
	const p = [...document.querySelectorAll('iframe.yomitan-popup')].find((f) => f.style.visibility === 'visible').getBoundingClientRect();
	log(`popup ${r(p)}`);
	const x = Math.min(Math.max(onWord.x, p.left + 20), p.right - 20);
	const y = p.bottom <= rect.top + 2 ? p.bottom - 40 : p.top >= rect.bottom - 2 ? p.top + 40 : p.top + p.height / 2;
	if (!await pointerMove(onWord, { x, y }, 250)) return;
	let since = 0;
	for (const at of [450, 850, 2350]) {
		await wait(at - since);
		since = at;
		equal(popupVisible(), true, `${at} ms in the popup: the popup is open`);
		equal(boxText('scan'), '晴れ', `${at} ms in the popup: the highlight`);
		equal(scanBoxes(), 1, `${at} ms in the popup: scan boxes`);
		equal(offset(), 0, `${at} ms in the popup: px between the box and the word`);
	}
});
