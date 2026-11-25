// Dialogue set at an angle (windows/slanted.swift, as Danganronpa's), read by Live Text in OCR Mode: its rows are drawn
// turned (OCRLayout.Line.turn), each character over where the window drew it (its span's middle within a third of the
// font size, and about as long as that along the row; upright they'd be up to half a row off at the ends of the 15°
// row), the two rows are one paragraph and 「はい、そうです」 turned −25° another (a line under 2.5 times as long as it's
// thick, as はい alone, keeps no angle of its own), and pointing at a character of the 15° row finds it and opens a
// popup.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "slanted", "title": "Slanted Test"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "scanDelay": 20, "scanModifier": "none", "autoHideResults": false, "hidePopupOnCursorExit": false, "ankiEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/slanted.swift")" "Slanted Test"
// timeout: 90

test('overlay', async () => {
	await windowStep('shown ', 30000);
	const glyphs = (await windowSteps()).map((s) => s.step.match(/^glyph (\S+) (\d+) (\d+)$/)).filter(Boolean)
		.map(([, text, x, y]) => ({ text, x: Number(x), y: Number(y) }));
	const text = document.querySelector('#ocr-text');
	await until('both rows and はい read', () => ['刃物', 'もので', 'そう'].every((t) => text.textContent.includes(t)), 30000)
		.catch(() => null);
	log(`read: ${JSON.stringify(text.textContent)}`);

	// Where a window point is in the page: probes in the OCR text, which is laid out in window points.
	const probe = (x, y) => {
		const element = document.createElement('div');
		element.style.cssText = `position: absolute; left: ${x}px; top: ${y}px; width: 0; height: 0;`;
		text.append(element);
		const rect = element.getBoundingClientRect();
		element.remove();
		return { x: rect.left, y: rect.top };
	};
	const origin = probe(0, 0);
	const unit = probe(100, 100);
	const toPage = (glyph) => ({ x: origin.x + (glyph.x * (unit.x - origin.x)) / 100, y: origin.y + (glyph.y * (unit.y - origin.y)) / 100 });

	// 1. The rows are drawn turned, about as the window turned them.
	const lineOf = (t) => [...text.querySelectorAll('.ocr-line')].find((line) => line.textContent.includes(t));
	for (const [t, degrees] of [['刃物', 8], ['もので', 15], ['そう', -25]]) {
		const line = lineOf(t);
		const angle = Number(line?.style.transform.match(/rotate\(([-\d.e]+)rad\)/)?.[1]) * (180 / Math.PI);
		near(angle, degrees, 3, `the row with ${t} turned by about ${degrees}° (${line?.style.transform || 'not turned'})`);
	}

	// 2. Each character where the window drew it.
	const spans = [...text.querySelectorAll('.ocr-char')];
	for (const t of ['鋭', '刃', '物', 'よ', 'も', 'で', 'ぅ', 'は', 'い', 'そ']) {
		const glyph = glyphs.find((g) => g.text === t);
		const span = spans.find((s) => s.textContent === t);
		if (!expect(glyph && span, `${t} drawn and read`)) continue;
		const at = toPage(glyph);
		const middle = center(span.getBoundingClientRect());
		const size = 44;
		const off = Math.hypot(middle.x - at.x, middle.y - at.y) / ((unit.x - origin.x) / 100);
		expect(off < size / 3, `${t} within a third of its size of where it was drawn (${off.toFixed(1)} points off)`);
		// Its length along the row (before it's turned) about its size: not its upright box's (59 points at −25°).
		near(span.offsetWidth, size, size * 0.3, `${t}'s length along the row`);
	}

	// 3. The two rows one paragraph, はい、 another (paragraphs are separated by "\n" text nodes).
	const paragraphs = text.textContent.split('\n');
	const dialogue = paragraphs.find((p) => p.includes('刃物'));
	expect(dialogue?.includes('もので') && !dialogue.includes('そう'), `the rows one paragraph without はい、そうです: ${JSON.stringify(paragraphs)}`);

	// 4. Pointing at で (15° row): the element there is its span, and a popup opens.
	const de = spans.find((s) => s.textContent === 'で');
	if (expect(de, 'で read')) {
		const point = center(de.getBoundingClientRect());
		equal(document.elementFromPoint(point.x, point.y)?.textContent, 'で', 'the character at で\'s middle');
		await native('debugMouse', point);
		expect(await until('the popup', popupVisible, 10000).catch(() => false), 'a popup on the 15° row');
		await native('debugMouse', { x: 5, y: 5 });
	}
});
