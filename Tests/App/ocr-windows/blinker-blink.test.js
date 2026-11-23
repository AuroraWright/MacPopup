// OCR Mode (Live Text) on a line with a blinking "next" icon (▼ shown and hidden every 0.5 s) 40 points after it
// (windows/blinker.swift): the icon's blocks are learned as animated, so it isn't read over and over (at most 40
// readings from the line until the icon goes (61 before 2026-11-14's learning, 10 after, with Screen AI)), and when the
// line then grows over where the icon was, they're unlearned ("text was read there") and the new text is read within
// 3 s.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "blinker", "title": "BlinkTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/blinker.swift")" BlinkTest 40 0.5 blink
// timeout: 120

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっている。';
	const expected = `${line}それでも`;
	const texts = watch(ocrText);
	const shown = await windowStep('line shown', 90000);
	const change = await windowStep('line longer', 20000);
	await wait(5000);
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - shown, t.value]))}`);
	const records = await debugRecords();
	const at = (r) => Date.parse(r.time);
	const readings = records.filter((r) => r.type === 'reading' && at(r) > shown && at(r) < change);
	expect(readings.length <= 40, `readings from the line until the icon went: ${readings.length} (at most 40)`);
	const messages = records.filter((r) => r.type === 'log').map((r) => ({ time: at(r), message: r.message }));
	const learned = messages.find((m) => m.time > shown && m.time < change && /^learned \d+ animated blocks/.test(m.message));
	expect(!!learned, `the icon learned as animated (${learned?.message ?? 'nothing learned'})`);
	const unlearned = messages.find((m) => m.time > change && /^unlearned \d+ animated blocks: text was read there/.test(m.message));
	expect(!!unlearned, `unlearned once text was read there (${unlearned?.message ?? 'not unlearned'})`);
	const read = texts.find((t) => t.time > change && t.value.replace(/\n/g, '') === expected);
	expect(read && read.time - change < 3000, `the new text shown within 3 s (after ${read ? read.time - change : '-'} ms)`);
	equal(ocrText().replace(/\n/g, ''), expected, 'the text at the end');
});
