// OCR Mode (Live Text) on a dialogue box over a moving background (windows/animbg.swift: diagonal stripes moving all the
// time, a line typed in 2 s), with "only check after input" off, so the window is read all along (the stripes are more
// than the share of a window learned as animated): the whole line is shown within 5 s of being complete, and until the
// end (about 30 s) it's what's shown at least 80% of the time, however often the window is read (Live Text sometimes
// splits it in rows or reads a stripe as 「; line breaks don't count). (The old runner's other cases need input: a
// posted mouse move, or none from the user at all.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "animbg", "title": "AnimTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/animbg.swift")" AnimTest
// timeout: 120

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっているんだよ。';
	const texts = watch(ocrText);
	const shown = await windowStep('shown', 90000);
	const start = (await windowSteps()).find((s) => s.step === 'start').time;
	await until('the window quitting', () => Date.now() > start + 39000, 45000);
	texts.stop();
	const end = Date.now();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - shown, t.value]))}`);
	const whole = texts.find((t) => t.time >= shown && t.value.replace(/\n/g, '') === line);
	expect(whole && whole.time - shown < 5000, `the whole line shown within 5 s (after ${whole ? whole.time - shown : '-'} ms)`);
	// How long the line was shown, from then until the end.
	let lineTime = 0;
	texts.forEach((t, i) => {
		if (whole && t.time >= whole.time && t.value.replace(/\n/g, '') === line) lineTime += (texts[i + 1]?.time ?? end) - t.time;
	});
	const share = whole ? lineTime / (end - whole.time) : 0;
	expect(share >= 0.8, `the line shown ${Math.round(share * 100)}% of the time after that`);
	equal(ocrText().replace(/\n/g, ''), line, 'the text at the end');
	const readings = (await debugRecords()).filter((r) => r.type === 'reading' && Date.parse(r.time) > shown);
	log(`${readings.length} readings after the line was complete`);
});
