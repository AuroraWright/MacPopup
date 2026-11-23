// OCR Mode (Live Text) on text that never settles (windows/vanish.swift): a line typed and cleared 0.15 s after it's
// complete, then a line scrolling through a box for 6 s. Each shows from its first partial readings, while it's on
// screen (readings while the text changes are shown, outlined as provisional); then hovering a character of the moving
// line opens a popup on it, and the highlight stays on that word, the popup open and the text as it was for 1.5 s while
// the line moves on (the readings wait for the popup: "shown once the popups close"). (Game Pause is off in tests, so
// the game isn't frozen meanwhile. A real click anywhere while the popup is open closes it, failing the test.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "vanish", "title": "VanishTest"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "scanModifier": "none", "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/vanish.swift")" VanishTest
// timeout: 120

test('overlay', async () => {
	const texts = watch(ocrText);
	const typedStart = await windowStep('typed start', 90000);
	const typedCleared = await windowStep('typed cleared', 10000);
	const tickerStart = await windowStep('ticker start', 10000);
	// The ticker's text shown: hover one of its characters.
	const index = (await until('the ticker\'s text', () => {
		const i = ocrText().search(/[鐘鳴呼気]/u);
		return i >= 0 ? { i } : null;
	}, 6000).catch(() => ({ i: -1 }))).i;
	const tickerShownAt = Date.now();
	let hovered = null;
	if (index >= 0) {
		const walker = document.createTreeWalker(document.querySelector('#ocr-text'), NodeFilter.SHOW_TEXT);
		let left = index, rect = null;
		for (let node = walker.nextNode(); node && !rect; node = walker.nextNode()) {
			if (left < node.length) {
				const range = document.createRange();
				range.setStart(node, left);
				range.setEnd(node, left + 1);
				rect = range.getBoundingClientRect();
			} else left -= node.length;
		}
		const at = { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) };
		await native('debugMouse', { x: at.x + 7, y: at.y + 5 });
		await wait(60);
		await native('debugMouse', at);
		await until('the popup', () => popupVisible() && boxText('scan'), 1500).catch(() => {});
		hovered = { time: Date.now(), word: boxText('scan'), text: ocrText(), popup: popupVisible() };
		await wait(1500);
	}
	const later = { word: boxText('scan'), text: ocrText(), popup: popupVisible() };
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - typedStart, t.value]))}`);
	const typed = texts.filter((t) => t.time >= typedStart && t.time <= typedCleared + 300 && /[扉向界]/u.test(t.value));
	expect(typed.length > 0 && typed[0].time - typedStart < 2500,
		`the typed line shown while it's on screen (${typedCleared - typedStart} ms): ${typed.length} texts, the first after ${typed[0] ? typed[0].time - typedStart : '-'} ms`);
	expect(index >= 0 && tickerShownAt - tickerStart < 3000, `the moving line shown within 3 s (after ${tickerShownAt - tickerStart} ms)`);
	expect(hovered?.popup && hovered.word.length > 0 && hovered.text.includes(hovered.word),
		`hovered: a popup on "${hovered?.word}" in "${hovered?.text}"`);
	equal(later, hovered && { word: hovered.word, text: hovered.text, popup: true }, '1.5 s later, the line moving on: the highlight, the text and the popup');
	const waited = (await debugRecords()).filter((r) => r.type === 'reading' && r.outcome === 'shown once the popups close'
		&& hovered && Date.parse(r.time) > hovered.time);
	expect(waited.length > 0, `readings waiting for the popup meanwhile: ${waited.length}`);
	const provisional = document.querySelector('#ocr-text .ocr-line');
	log(`line classes at the end: ${provisional?.className}`);
});
