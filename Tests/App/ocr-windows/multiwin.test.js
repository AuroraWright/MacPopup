// OCR Mode (Live Text) with an untitled saved window whose app also has hidden untitled windows listed before it, as a
// Windows app in Parallels' Coherence mode does (windows/multiwin.swift): the one on screen is read, so its line is
// shown within 10 s of the window opening (before 2026-11-15's fix, a hidden window was picked and it was never read).
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "multiwin", "title": ""}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/multiwin.swift")"
// timeout: 120

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっている。';
	const texts = watch(ocrText);
	const start = await windowStep('start', 90000);
	await until('the line', () => ocrText() === line, 15000).catch(() => {});
	await wait(2000);
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - start, t.value]))}`);
	const shown = texts.find((t) => t.value === line);
	expect(shown && shown.time - start < 10000, `the line shown within 10 s (after ${shown ? shown.time - start : '-'} ms)`);
	equal(ocrText(), line, 'the text at the end');
});
