// "Read text from OCR" (Live Text, WebSocket lines) on a visual novel's page (windows/novel.swift), as novel-box, with a
// switch to the OCR overlay 24 s in (the window's time; after the paused line, before the two paragraphs at once) and
// back to the Floating Window at 37 s (after the hooked line): the text box still gets every line once, as on the page,
// in order, and meanwhile the overlay shows the page's text over the window (風が強い。/空が暗い。, then the hooked line).
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// settings: {"ocrMode": false, "floatingWindowOCR": true, "preventLastDuplicate": 0, "preventGlobalDuplicate": false, "mergeEqualLineStarts": false, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "novel", "title": "NovelTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/novel.swift")"
// timeout: 150

test('overlay', async () => {
	const expected = [
		'この街に来てから、もう三年が経った。毎朝同じ道を歩き、同じ店でパンを買い、同じ時間に家を出る。',
		'「おはよう。今日は早いね。」',
		'「うん、ちょっと用事があって……」',
		'そう言って彼女は笑った。',
		'それから、駅へ向かった。',
		'風が強い。空が暗い。',
		'扉の向こうに、まだ誰も知らない世界が広がっている。',
		'これはフックされない行です。',
		'遅れて届く行がここにある。',
		'隠れていても読める行。',
	];
	const boxLines = () => [...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent.trim());
	const box = watch(boxLines, 100);
	const overlay = watch(() => [...document.querySelectorAll('#ocr-text .ocr-line')].map((line) => line.textContent).join('|'), 100);
	const switchTo = async (ocrMode) => {
		await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ocrMode }) });
		log(`${Date.now()} switched: ocrMode ${ocrMode}`);
	};
	const start = await windowStep('start', 90000);
	await until('24 s', () => Date.now() > start + 24000, 30000);
	await switchTo(true);
	await until('37 s', () => Date.now() > start + 37000, 20000);
	const shownInOverlay = overlay.filter((o) => o.time > start + 24000).map((o) => o.value);
	await switchTo(false);
	await until('the window quitting', () => Date.now() > start + 67000, 40000);
	box.stop();
	overlay.stop();
	log(`box: ${JSON.stringify(box.map((b) => [b.time - start, b.value]))}`);
	log(`overlay: ${JSON.stringify(overlay.map((o) => [o.time - start, o.value]))}`);
	expect(shownInOverlay.includes('風が強い。|空が暗い。') || shownInOverlay.includes('風が強い。空が暗い。'),
		`the overlay showed the two paragraphs (${JSON.stringify(shownInOverlay)})`);
	expect(shownInOverlay.includes('扉の向こうに、まだ誰も知らない世界が広がっている。'), 'the overlay showed the hooked line');
	// (Live Text reads "……" as a row of "・".)
	const dots = (lines) => lines.map((line) => line.replace(/[…・.]+/g, '…'));
	equal(dots(boxLines()), dots(expected), 'the text box\'s lines (dot runs as one …)');
});
