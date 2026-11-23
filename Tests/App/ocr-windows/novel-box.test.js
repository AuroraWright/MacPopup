// "Read text from OCR" in the Floating Window (Live Text, WebSocket lines) on a visual novel's page (windows/novel.swift):
// a wrapped page, typed paragraphs, one without a sentence end, a pause mid-line, two paragraphs at once, a hooked line,
// an unhooked one, a hooked line arriving 2.5 s late, and a line shown while the window is covered. The text box gets
// every line once, as on the page, in order (2026-11-15: before the reach learning, the paragraph without a sentence end
// joined the next one; before the edit-distance alignment, a misread "……" dropped or doubled a character).
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
	const start = await windowStep('start', 90000);
	await until('the window quitting', () => Date.now() > start + 67000, 80000);
	box.stop();
	log(`box: ${JSON.stringify(box.map((b) => [b.time - start, b.value]))}`);
	// (Live Text reads "……" as a row of "・".)
	const dots = (lines) => lines.map((line) => line.replace(/[…・.]+/g, '…'));
	equal(dots(boxLines()), dots(expected), 'the text box\'s lines (dot runs as one …)');
});
