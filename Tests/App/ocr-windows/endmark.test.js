// OCR Mode (Live Text) on a short line with a "next" icon right after it that OCR reads as a bracket (a row of its own)
// one time and not the next (windows/endmark.swift; as a game's, Phantom of Inferno 2026-11-23, where Screen AI read it
// as 』 or 」). The icon's changes used to
// start a reading round every half second for as long as the line was there (and in the game, each other bracket made
// the line a new one, too short to pass for the same line read differently: see Tests/Unit/ShownLinesTests.swift).
// Now marks at the end of a row that come and go are learned as animated, so the readings stop within a few seconds,
// and the line stays one line.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "endmark", "title": "EndMarkTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 150, "ocrSettleTime": 250, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/endmark.swift")" EndMarkTest
// timeout: 90

test('overlay', async () => {
	const shown = await windowStep('line shown', 60000);
	await wait(20000);
	const records = await debugRecords();
	const at = (r) => Date.parse(r.time);
	const messages = records.filter((r) => r.type === 'log' && at(r) > shown).map((r) => r.message);
	const readings = (from, to) => records.filter((r) => r.type === 'reading' && at(r) > shown + from && at(r) <= shown + to).length;
	log(`readings by 4 s: ${[0, 4, 8, 12, 16].map((s) => readings(s * 1000, (s + 4) * 1000)).join(', ')}`);
	const learned = messages.find((m) => /^learned \d+ animated blocks/.test(m));
	expect(!!learned, `the icon learned as animated (${learned ?? 'nothing learned'})`);
	const late = readings(10000, 20000);
	expect(late <= 4, `readings 10-20 s after the line was shown: ${late} (at most 4)`);
	const lines = messages.filter((m) => /^line \d+ (new|grew|again)/.test(m));
	const added = lines.filter((m) => / new, /.test(m));
	expect(added.length === 1, `one line: ${added.length} new (${added.map((m) => m.replace(/, read with OCR/, '')).join(' / ')}; ${lines.length} noted)`);
	expect(ocrText().includes('殺される'), `the line is shown: "${ocrText()}"`);
});
