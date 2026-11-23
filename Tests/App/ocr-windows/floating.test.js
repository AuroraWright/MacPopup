// OCR Mode (Live Text) on a captured window kept on top (windows/floater.swift, at the floating window level): the
// window picker and the saved window used to list only normal windows, so a floating one was never found and nothing
// was read. Its line is read and shown whole within 5 s.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "floater", "title": "FloatTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/floater.swift")" FloatTest
// timeout: 90

const LINE = '今日は朝から雨が降っていて、少し寒い。';

test('overlay', async () => {
	const line = await windowStep('line', 60000);
	const read = await until('the line', () => ocrText() === LINE, 15000).then(() => Date.now()).catch(() => null);
	expect(read !== null && read - line < 5000, `the floating window's line is shown whole within 5 s (after ${read === null ? '-' : read - line} ms): "${ocrText()}"`);
	const shown = (await runFile('beside.log')).match(/start (\d+)/);
	equal(shown?.[1], '3', 'the window is at the floating level');
});
