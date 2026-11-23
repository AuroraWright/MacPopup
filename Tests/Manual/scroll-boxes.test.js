// The controller's cursor box while the text box is scrolled with a trackpad: the box must stay on its character, which
// a page can't see (WebKit scrolls the text on its own thread, so the boxes' place in the page is right even when the
// screen shows them a frame or more off). Twenty lines go into an opaque text box, the controller's cursor box onto a
// character; a person scrolls the box up and down for about 15 s when asked, and the driver records the overlay window
// alone (tools/rec-window.swift) into scroll.mov in the run folder, from the first scroll. Look through it frame by
// frame (QuickTime: the arrow keys): the box stays on the same glyph in every frame, also in fast scrolls (before the
// boxes moved into the scrolled element, 2026-11-23, they were off by up to a line). From
// evals/popup-timing/scroll-rec.sh.
// Needs a person at the Mac, with a trackpad or a mouse that scrolls; records only the test instance's window.
// interactive
// settings: {"clipboardMonitor": true, "gamepadScanButtons": ["Button A"], "scanResolution": "character", "gamepadPopupDelay": 600000, "boxOpacity": 1, "boxRect": {"x": 559, "y": 700, "width": 1030, "height": 362}}
// driver: python3 -I "$REPO/Tests/Manual/scroll-boxes-driver.py"
// timeout: 330

test('overlay', async () => {
	const sentences = ['今日はとても寒いですね', '駅まで歩いて行きました', '彼は何も言わなかった', 'もう少し待ってください', '本当にそう思うの？', 'それは秘密です'];
	for (let i = 0; i < 20; i++) {
		window.__macpopupClipboard(`${sentences[i % sentences.length]}${i}`);
		await wait(150);
	}
	await lineWith('それは秘密です17');
	await wait(1000);
	await gamepadPress(['Button A']);
	await gamepadPress(['Direction Pad Up']);
	await gamepadPress(['Direction Pad Up']);
	const lines = document.querySelector('#lines');
	const cursor = boxText('gamepad');
	expect(cursor.length === 1, `the controller's cursor box is on a character: "${cursor}"`);
	expect(lines.scrollHeight > lines.clientHeight, `the box can scroll: ${lines.scrollHeight - lines.clientHeight} px`);
	log('box');
	let first = 0;
	let last = 0;
	lines.addEventListener('scroll', () => {
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
	// The box's character is read from the screen's point under it, so it has to be in view, wherever the scrolling ended.
	document.querySelector('.highlight-boxes > .gamepad')?.scrollIntoView({ block: 'center' });
	await wait(500);
	equal(boxText('gamepad'), cursor, "the controller's cursor box after the scrolling: on the same character");
});
