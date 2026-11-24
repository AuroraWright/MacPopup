// The scanned word's highlight boxes in the text box go from the screen when its popup closes: six lines a user had,
// with words in text nodes of their own as with Yomitan's tokens (MOCK_TOKENIZE=words: 心底 and 、, 花 and びらを, 思 and
// った),
// with the user's line bullets (which repaint as the pointer comes and goes) and popup size. Each word is hovered with
// the simulated pointer, which then moves along it to its last character as a hand does and goes off the text. The
// page's boxes must be over the word and gone after; and the driver's screenshots of the overlay's window (by window
// only) must show the highlight where its first box is (which the popup is clear of: the highlight can wrap to the row
// below, where the popup goes), then what was there before where all of its boxes were (2026-11-24: WebKit left the
// word's second box on screen, e.g. 、 after 心底, until the highlight layer had a size of its own).
// mock: MOCK_RUN_FILES=1 MOCK_MATCH_LENGTH=3 MOCK_TOKENIZE=words
// settings: {"clipboardMonitor": true, "showLinePoints": true, "theme": "dark", "linePadding": 0, "termSpacing": false, "enableLineAnimation": true, "scanModifier": "none", "scanDelay": 150, "selectMatchedText": true, "hidePopupOnCursorExit": true, "autoHideResults": true, "hideDelay": 100, "popupWidth": 1000, "popupHeight": 1050, "boxRect": {"x": 514, "y": 160, "width": 1046, "height": 304}}
// driver: python3 -I "$REPO/Tests/App/overlay/highlight-clear-driver.py"
// timeout: 150

test('overlay', async () => {
	const lines = [
		'初恋……憧れの女の子……',
		'父さん……母さん……',
		'受験勉強……入試……卒業式……',
		'あのとき、桜並木は満開だった。',
		'別れを惜しみ、門出を祝って舞い落ちる花びらを、心底、きれいだと思った。',
		'あれは桜。日本の花……遠い彼方の、故郷の花……',
	];
	for (const line of lines) {
		window.__macpopupClipboard(line);
		await lineWith(line.slice(0, 4));
	}
	await wait(1500);
	const r = (b) => `${Math.round(b.left)},${Math.round(b.top)} ${Math.round(b.width)}x${Math.round(b.height)}`;
	const scanBoxes = () => [...document.querySelectorAll('#box-highlights > .scan')];
	const p = await lineWith('心底');
	const line = p.getBoundingClientRect();
	// The driver's screenshot, compared with the one before where `rect` is (see highlight-clear-driver.py).
	const shot = async (name, rect = line) => {
		log(`shot ${name} ${rect.left} ${rect.top} ${rect.width} ${rect.height}`);
		await until(`the screenshot ${name}`, async () => (await runFile(`${name}.done`)) !== '', 15000)
			.catch(() => expect(false, `the screenshot ${name} was taken`));
	};
	// Around the boxes.
	const boxesRect = (boxes) => {
		const rects = boxes.map((b) => b.getBoundingClientRect());
		const left = Math.min(...rects.map((b) => b.left)) - 2;
		const top = Math.min(...rects.map((b) => b.top)) - 2;
		return { left, top, width: Math.max(...rects.map((b) => b.right)) + 2 - left, height: Math.max(...rects.map((b) => b.bottom)) + 2 - top };
	};
	const popupRect = () => [...document.querySelectorAll('iframe.yomitan-popup')].find((f) => f.style.visibility === 'visible')?.getBoundingClientRect();
	const overlaps = (a, b) => !!a && !!b && a.left < b.left + b.width && b.left < a.right && a.top < b.top + b.height && b.top < a.bottom;
	const box = document.querySelector('#box').getBoundingClientRect();
	const off = { x: box.left + 20, y: box.bottom - 10 };
	await native('debugMouse', off);
	await wait(800);
	await shot('before');
	for (const [word, name] of [['心底', 'shintei'], ['花びら', 'hanabira'], ['思った', 'omotta']]) {
		const first = rangeOf(p, word[0]).getBoundingClientRect();
		await native('debugMouse', { x: first.left + first.width / 4, y: first.top + first.height / 2 });
		await until(`the popup on ${word}`, () => popupVisible() && scanBoxes().length > 0, 10000).catch(() => {});
		await wait(600);
		log(`${word}: boxes ${scanBoxes().map((b) => r(b.getBoundingClientRect())).join(' | ')}, text ${boxText('scan')}`);
		expect(boxText('scan').startsWith(word), `the highlight on ${word}`);
		// Along the word to its last character (a step every 100 ms), staying there for its popup.
		for (let x = first.left + first.width / 4; x <= first.left + first.width * (word.length - 0.5); x += 6) {
			await native('debugMouse', { x, y: first.top + first.height / 2 });
			await wait(100);
		}
		await wait(900);
		log(`${word} at its end: popup ${popupVisible()}, text ${boxText('scan')}`);
		// (Else the shots below would compare the whole line, where its bullet alone can change enough.)
		expect(scanBoxes().length > 0, `${word} highlighted at its end`);
		const where = scanBoxes().length > 0 ? boxesRect(scanBoxes()) : line;
		const firstBox = scanBoxes().length > 0 ? boxesRect(scanBoxes().slice(0, 1)) : line;
		expect(!overlaps(popupRect(), firstBox), `the popup on ${word} is clear of the highlight's first box`);
		await shot(`${name}-end`, firstBox);
		await native('debugMouse', off);
		await until(`the popup on ${word} closed`, () => !popupVisible(), 10000).catch(() => {});
		await wait(800);
		equal(scanBoxes().length, 0, `boxes left after the popup on ${word} closed`);
		await shot(`${name}-closed`, where);
	}
});
