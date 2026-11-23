// OCR Mode (Live Text) on a line with a blinking "next" icon (▼ every 0.5 s) 300 points after it
// (windows/blinker.swift, BLINKER_REPLACE=1): the icon's blocks are learned as animated, so it isn't read over and over
// (at most 40 readings from the line until the icon goes; Live Text reads a spinner as つ at times), and when the icon
// goes and a character (終) is drawn where it was instead, the only change there, that character is read within 3 s.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "blinker", "title": "BlinkTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: BLINKER_REPLACE=1 "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/blinker.swift")" BlinkTest 300 0.5 blink
// timeout: 120

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっている。';
	const expected = `${line}終`;
	const texts = watch(ocrText);
	const shown = await windowStep('line shown', 90000);
	const change = await windowStep('character where the icon was', 20000);
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
	// (Live Text reads the character as a row of its own.)
	const read = texts.find((t) => t.time > change && t.value.replace(/\n/g, '') === expected);
	expect(read && read.time - change < 3000, `the new text shown within 3 s (after ${read ? read.time - change : '-'} ms)`);
	equal(ocrText().replace(/\n/g, ''), expected, 'the text at the end');
});
