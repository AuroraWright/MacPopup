// OCR Mode (Live Text) on a short line with a "next" icon right after it that OCR reads as a letter one time and not the
// next (windows/endmark.swift with "letter": 上, as Screen AI read Phantom of Inferno's icon on 2026-11-24, where the line
// became 「……殺される……上」 and each blink started a reading round). One or two characters at the end of a row that go
// away and come back twice while the rest stays the same are left out like end marks: the readings stop within a few
// seconds, the line stays one line without 上, and the next line (21 s after it, the icon going on) is still read.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "endmark", "title": "EndMarkTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 150, "ocrSettleTime": 250, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/endmark.swift")" EndMarkTest 32 letter
// timeout: 90

test('overlay', async () => {
	const shown = await windowStep('line shown', 60000);
	await wait(20000);
	const records = await debugRecords();
	const at = (r) => Date.parse(r.time);
	const messages = records.filter((r) => r.type === 'log' && at(r) > shown).map((r) => r.message);
	const readings = (from, to) => records.filter((r) => r.type === 'reading' && at(r) > shown + from && at(r) <= shown + to);
	log(`readings by 4 s: ${[0, 4, 8, 12, 16].map((s) => readings(s * 1000, (s + 4) * 1000).length).join(', ')}`);
	const read = [...new Set(readings(0, 20000).flatMap((r) => (r.recognized ?? []).map((line) => line.text)))];
	log(`read: ${JSON.stringify(read)}`);
	expect(read.some((text) => text.endsWith('上')), 'Live Text read the icon as 上 (or this test checks nothing)');
	const learned = messages.find((m) => /^learned \d+ animated blocks/.test(m));
	expect(!!learned, `the icon learned as animated (${learned ?? 'nothing learned'})`);
	const late = readings(10000, 20000).length;
	expect(late <= 4, `readings 10-20 s after the line was shown: ${late} (at most 4)`);
	const lines = messages.filter((m) => /^line \d+ (new|grew|again)/.test(m));
	const added = lines.filter((m) => / new, /.test(m));
	expect(added.length === 1, `one line: ${added.length} new (${added.map((m) => m.replace(/, read with OCR/, '')).join(' / ')}; ${lines.length} noted)`);
	expect(ocrText().includes('殺される') && !ocrText().includes('上'), `the line is shown without 上: "${ocrText()}"`);
	// (So that fewer readings aren't from the capture having stopped.)
	await windowStep('line changed', 15000);
	const next = await until('the next line shown', () => ocrText().includes('生きている'), 8000).catch(() => false);
	expect(!!next, `the next line shown: "${ocrText()}"`);
});
