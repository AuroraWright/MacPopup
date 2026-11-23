// OCR Mode (Live Text) on a sparse chapter screen (windows/sparse.swift): "第1章" small at the top left, then nothing,
// then a short 17 pt line in the middle of a 1600x1000 window. Each is read while it's on screen: 第1章 within 5 s,
// the empty screen clears the text, and the line is shown whole within 5 s and stays.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "sparse", "title": "SparseTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/sparse.swift")" SparseTest
// timeout: 120

test('overlay', async () => {
	const texts = watch(ocrText);
	const chapter = await windowStep('shown "第1章"', 90000);
	const cleared = await windowStep('shown ""', 40000);
	const line = await windowStep('shown "“視線”', 10000);
	await wait(8000);
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - chapter, t.value]))}`);
	const first = (from, to, match) => texts.find((t) => t.time >= from && t.time < to && match(t.value));
	const chapterShown = first(chapter, cleared, (v) => v.includes('第1章'));
	expect(chapterShown && chapterShown.time - chapter < 5000,
		`第1章 shown within 5 s (after ${chapterShown ? chapterShown.time - chapter : '-'} ms)`);
	const empty = first(cleared, line, (v) => v === '');
	expect(!!empty, `the text cleared before the line came (after ${empty ? empty.time - cleared : '-'} ms)`);
	const lineShown = first(line, Infinity, (v) => v.includes('視線') && v.includes('見えない'));
	expect(lineShown && lineShown.time - line < 5000,
		`the line shown within 5 s (after ${lineShown ? lineShown.time - line : '-'} ms: ${lineShown?.value})`);
	// (Live Text may leave out a quotation mark.)
	equal(ocrText().replace(/["“”]/g, ''), '視線は見えない。', 'the text at the end, without quotation marks');
});
