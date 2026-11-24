// "Read text from OCR" in the Floating Window with text replacements (windows/novel.swift, as novel-box.test.js): the
// readings get them before they're matched with the hooked lines, as those lines do, so a hooked line that's shown is
// still added once, also with text a replacement changed (the hooked line arriving late, the one that's shown when it
// arrives); and once only (三年 → 三年間 applied twice would be 三年間間). (Before 2026-11-24, readings were matched as
// read, and lines a replacement changed were added twice.)
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// settings: {"ocrMode": false, "floatingWindowOCR": true, "preventLastDuplicate": 0, "preventGlobalDuplicate": false, "mergeEqualLineStarts": false, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "novel", "title": "NovelTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "replacements": [{"pattern": "[「」]", "replaces": "", "flags": ["g"], "enabled": true}, {"pattern": "三年", "replaces": "三年間", "flags": [], "enabled": true}, {"pattern": "扉の向こうに、", "replaces": "", "flags": [], "enabled": true}, {"pattern": "遅れて届く", "replaces": "遅延の", "flags": [], "enabled": true}], "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/novel.swift")"
// timeout: 150

test('overlay', async () => {
	const expected = [
		'この街に来てから、もう三年間が経った。毎朝同じ道を歩き、同じ店でパンを買い、同じ時間に家を出る。',
		'おはよう。今日は早いね。',
		'うん、ちょっと用事があって……',
		'そう言って彼女は笑った。',
		'それから、駅へ向かった。',
		'風が強い。空が暗い。',
		'まだ誰も知らない世界が広がっている。',
		'これはフックされない行です。',
		'遅延の行がここにある。',
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
