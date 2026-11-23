// The popup's highlight box while the popup is scrolled with a trackpad: it must stay on its word, which a page can't
// see (WebKit scrolls the popup on its own thread, as the text box). A hover with Shift (scanModifier shift, so the
// real pointer looks nothing up on its way to the popup) opens the popup on 晴, a word in the middle of its 150 entries
// is looked up (Popup.scanAt: its highlight box), and a person scrolls the popup up and down for about 15 s when asked
// while the driver records the overlay window alone into scroll.mov in the run folder. Look through it frame by frame
// (QuickTime: the arrow keys): the box stays on its word in every frame (2026-11-23, after the boxes moved into the
// scrolled element: in all 23 whole frames, moving 40–260 px a frame). The page checks the box is still on the word
// after the scrolling. From evals/popup-timing/popup-scroll-run.js.
// Needs a person at the Mac, with a trackpad or a mouse that scrolls; records only the test instance's window.
// interactive
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "scanModifier": "shift", "hidePopupOnCursorExit": false, "autoHideResults": false, "boxOpacity": 1, "boxRect": {"x": 559, "y": 900, "width": 1030, "height": 362}}
// driver: python3 -I "$REPO/Tests/Manual/scroll-boxes-driver.py" "the popup (its list of entries)"
// timeout: 330

test('overlay', async () => {
	const line = await lineWith('明日も晴れるといいね');
	const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
	let range = null;
	for (let node = walker.nextNode(); node && !range; node = walker.nextNode()) {
		const i = node.data.indexOf('晴');
		if (i >= 0) {
			range = document.createRange();
			range.setStart(node, i);
			range.setEnd(node, i + 1);
		}
	}
	const rect = range.getBoundingClientRect();
	await native('debugMouse', { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, shift: true });
	expect(await until('the popup', () => popupVisible(), 10000).catch(() => false), 'the popup opens');
	await wait(800);
	const frame = document.querySelector('iframe.yomitan-popup');
	const doc = frame.contentDocument;
	const scroller = doc.querySelector('#content-scroll');
	const view = scroller.getBoundingClientRect();
	expect(scroller.scrollHeight > scroller.clientHeight, `the popup can scroll: ${scroller.scrollHeight - scroller.clientHeight} px`);

	// A word's first letter in the middle of the popup.
	const entries = doc.createTreeWalker(doc.querySelector('#dictionary-entries'), NodeFilter.SHOW_TEXT);
	let target = null;
	for (let node = entries.nextNode(); node && !target; node = entries.nextNode()) {
		for (let i = 1; i < node.data.length - 6 && !target; i++) {
			if (!/\s/.test(node.data[i - 1]) || !/\w/.test(node.data[i])) continue;
			const c = doc.createRange();
			c.setStart(node, i);
			c.setEnd(node, i + 1);
			const top = c.getBoundingClientRect().top;
			if (top > view.top + view.height * 0.4 && top < view.top + view.height * 0.6) target = c;
		}
	}
	expect(target, 'a word in the middle of the popup');
	const t = target.getBoundingClientRect();
	await frame.contentWindow.macpopupPopup.scanAt(t.left + t.width / 2, t.top + t.height / 2);
	await wait(1000);
	const letter = target.toString();
	/** The letter under the popup's (first) highlight box, from the popup's own point under it. */
	const underBox = () => {
		const box = doc.querySelector('#scan-highlights > div');
		if (!box) return null;
		const b = box.getBoundingClientRect();
		const caret = doc.caretRangeFromPoint(b.left + 1, b.top + b.height / 2);
		return caret ? caret.startContainer.data?.[caret.startOffset] ?? '' : '';
	};
	equal(underBox(), letter, 'the highlight box is on the word looked up');
	log('box');

	let first = 0;
	let last = 0;
	scroller.addEventListener('scroll', () => {
		last = performance.now();
		if (!first) {
			first = last;
			log('scrolling');
		}
	}, { passive: true });
	// Until 6 s after the last scroll and at least 20 s after the first (the recording takes 15), or 4 minutes without.
	const start = performance.now();
	const scrolling = () => performance.now() - last < 6000 || performance.now() - first < 20000;
	while (first ? scrolling() : performance.now() - start < 240000) await wait(200);
	expect(first > 0, `scrolled for ${first ? Math.round((last - first) / 1000) : 0} s`);
	equal(doc.querySelectorAll('#scan-highlights > div').length, 1, 'one highlight box after the scrolling');
	// Read from the screen's point under it, so the word has to be in view, wherever the scrolling ended.
	target.startContainer.parentElement.scrollIntoView({ block: 'center' });
	await wait(500);
	equal(underBox(), letter, 'the highlight box after the scrolling: on the same word');
});
