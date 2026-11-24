// The scanned word's highlight boxes in the text box go from the screen when its popup closes: six lines a user had,
// with words as Yomitan's tokens are (MOCK_TOKENIZE=words: 心底 and 、, 花 and びら, 思 and った in text nodes of their own),
// with the user's line bullets (which repaint as the pointer comes and goes) and popup size. Each word is hovered with
// the simulated pointer, which then moves along it to its last character as a hand does and goes off the text. The
// page's boxes must be over the word and gone after; and the driver's screenshots of the overlay's window (by window
// only) must show the highlight, then the line as it was before (2026-11-24: WebKit left the word's second box on
// screen, e.g. 、 after 心底, until the highlight layer had a size of its own).
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
	// The driver's screenshot of the line (see highlight-clear-driver.py).
	const shot = async (name) => {
		log(`shot ${name} ${line.left} ${line.top} ${line.width} ${line.height}`);
		await until(`the screenshot ${name}`, async () => (await runFile(`${name}.done`)) !== '', 15000).catch(() => {});
	};
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
		await shot(`${name}-end`);
		await native('debugMouse', off);
		await until(`the popup on ${word} closed`, () => !popupVisible(), 10000).catch(() => {});
		await wait(800);
		equal(scanBoxes().length, 0, `boxes left after the popup on ${word} closed`);
		await shot(`${name}-closed`);
	}
});
