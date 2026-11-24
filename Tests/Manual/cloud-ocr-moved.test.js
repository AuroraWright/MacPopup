// OCR Mode with a cloud engine (Google Lens) after the game's window moves (tools/mover.swift: a line, then the window
// 150 points to the left, the text the same): the line is read by the cloud engine again, not given the reading from
// before the move (its boxes are in window points, so they'd be where the text was), and its characters are shown
// where the text is now. The cloud requests are counted in app.log ("googleLens: <s>s for <w>x<h>").
// Needs the network, and sends the test window's picture (the line above, nothing else) to Google: ask before running.
// No person needed.
// interactive
// network
// mock: MOCK_RUN_FILES=1
// env: MACPOPUP_DEBUG_OCR=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "googleLens", "ocrWindow": {"ownerName": "mover", "title": "MoverTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false, "gamePause": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/Manual/tools/mover.swift")" MoverTest
// timeout: 120

const LINE = '今日は朝から雨が降っていて、少し寒い。';

async function cloudRequests() {
	return (await runFile('app.log')).split('\n').filter((line) => /googleLens: [\d.]+s for \d+x\d+/.test(line)).length;
}

/** The left of the first shown character, in the overlay's points, or null. */
function firstLeft() {
	const char = document.querySelector('#ocr-text .ocr-char');
	return char ? Math.round(char.getBoundingClientRect().left) : null;
}

test('overlay', async () => {
	await windowStep('line', 60000);
	const read = await until('the line', () => ocrText() === LINE, 15000).catch(() => false);
	expect(read, `the line is read: "${ocrText()}"`);
	await wait(3000);
	const before = { requests: await cloudRequests(), left: firstLeft() };
	expect(before.requests >= 1, `Google Lens read it: ${before.requests} requests`);

	const moved = await windowStep('moved', 30000);
	log(`moved at ${moved}`);
	const again = await until('a cloud request after the move', async () => (await cloudRequests()) > before.requests, 15000)
		.catch(() => false);
	expect(again, `Google Lens reads the line again after the move: ${await cloudRequests()} requests (${before.requests} before)`);
	await until('the line moved', () => firstLeft() !== null && before.left - firstLeft() > 100, 10000).catch(() => {});
	await wait(1000);
	equal(ocrText(), LINE, 'the text after the move');
	const shift = before.left - firstLeft();
	expect(Math.abs(shift - 150) <= 6, `its characters moved with the window: ${shift} points left (150)`);
});
