// OCR Mode (Live Text, WebSocket lines, "only check after input" on) on a line sent as a text hook would and typed a
// character every 250 ms (windows/typer.swift): its start is shown while it's typed (within 5 s); the controller's scan
// button (A) then opens a popup on it, and while the popup is open the text shown stays as it is (readings wait for the
// popup: "shown once the popups close") as the line goes on; A again closes it, and the whole line is then shown,
// matched with the WebSocket line, within 9 s. (Game Pause is off in tests, so the game isn't frozen meanwhile. A real
// click anywhere while the popup is open closes it, failing the test.)
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "typer", "title": "TyperTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": true, "ocrMouseWatchTime": 2000, "ocrPollInterval": 100, "ocrShowBoxes": true, "gamepadScanButtons": ["Button A"], "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/typer.swift")" TyperTest
// timeout: 120

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっているんだよ。';
	const texts = watch(ocrText);
	const sent = await windowStep('line sent', 90000);
	const first = await until('the first text', () => ocrText(), 10000).catch(() => '');
	const firstAt = Date.now();
	expect(first && first.length < line.length && line.startsWith(first.replace(/\n/g, '')) && firstAt - sent < 5000,
		`the line's start shown while it's typed, within 5 s: "${first}" after ${firstAt - sent} ms`);
	await wait(300);
	await gamepadPress(['Button A'], { after: 100 });
	await until('the popup', () => popupVisible() && boxText('scan'), 3000).catch(() => {});
	const opened = Date.now();
	const held = ocrText();
	const word = boxText('scan');
	expect(popupVisible() && word && held.includes(word), `A: a popup on the text shown ("${held}"), its word "${word}"`);
	await wait(4000);
	equal(ocrText(), held, 'the text shown 4 s later, the popup open');
	equal(popupVisible(), true, 'the popup still open');
	await gamepadPress(['Button A'], { after: 300 });
	const closed = Date.now();
	equal(popupVisible(), false, 'A again: the popup is open');
	await until('the whole line matched', () => ocrText() === line && document.querySelector('#ocr-text .ocr-matched'), 9000).catch(() => {});
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - sent, t.value]))}`);
	const whole = texts.find((t) => t.time > closed && t.value === line);
	expect(whole && whole.time - closed < 9000, `the whole line shown within 9 s of closing the popup (after ${whole ? whole.time - closed : '-'} ms)`);
	equal(!!document.querySelector('#ocr-text .ocr-matched'), true, 'matched with the WebSocket line');
	const waited = (await debugRecords()).filter((r) => r.type === 'reading' && r.outcome === 'shown once the popups close'
		&& Date.parse(r.time) > opened && Date.parse(r.time) < closed);
	expect(waited.length > 0, `readings waiting for the popup while it was open: ${waited.length}`);
});
