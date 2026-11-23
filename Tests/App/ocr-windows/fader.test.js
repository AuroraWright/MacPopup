// OCR Mode (Live Text) on a line dissolved cell by cell (windows/fader.swift, 1.5 s, 3 pt cells, as games' transitions
// do), with another line in the same place 5 s after the fade started: the first line is shown within 5 s, the overlay
// is cleared as it fades, before the second line comes, and the second line is shown whole within 5 s and stays.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "fader", "title": "FaderTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/fader.swift")" FaderTest 1.5 3
// timeout: 120

test('overlay', async () => {
	const firstLine = 'というわけで、こんな街は即刻滅ぶべきだね。';
	const secondLine = 'でもこの部屋の住み心地はまあまあ我慢できる。';
	const texts = watch(ocrText);
	const first = await windowStep('first line', 90000);
	const fading = await windowStep('fading', 20000);
	const faded = await windowStep('faded', 10000);
	const second = await windowStep('second line', 10000);
	await wait(8000);
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - first, t.value]))}`);
	const find = (from, to, match) => texts.find((t) => t.time >= from && t.time < to && match(t.value));
	const firstShown = find(first, fading, (v) => v === firstLine);
	expect(firstShown && firstShown.time - first < 5000, `the first line shown within 5 s (after ${firstShown ? firstShown.time - first : '-'} ms)`);
	// (Once it can't be read, which may be a moment before its last cells go.)
	const empty = find(fading, second, (v) => v === '');
	expect(!!empty, `the text cleared as the line faded (${empty ? empty.time - faded : '-'} ms after it was gone)`);
	const secondShown = find(second, Infinity, (v) => v === secondLine);
	expect(secondShown && secondShown.time - second < 5000, `the second line shown within 5 s (after ${secondShown ? secondShown.time - second : '-'} ms)`);
	equal(ocrText(), secondLine, 'the text at the end');
});
