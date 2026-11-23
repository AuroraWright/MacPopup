// Where the controller starts in OCR Mode text (fake readings; WebSocket lines from mock.py): the character under the
// cursor right after the scan key, for each reading. Readings still changing ("appearing", provisional) have no lines
// yet and start by gamepadOcrStart: the bottom paragraph (left one in vertical text) with "bottom", the top (right) one
// with "top". Settled ones start on the newest line, preferring WebSocket ones: the first row of a reading, the row a
// sentence was added to, the row matching the latest WebSocket line (not a name row above it).
// mock: MOCK_WEBSOCKET=1
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "ocrUseWebsocket": true, "websocketUrls": ["ws://127.0.0.1:59880"], "gamepadScanButtons": ["Button A"], "gamepadOcrStart": "bottom", "ocrShowBoxes": true, "ankiEnabled": false, "gamePause": false}
// timeout: 120

test('overlay', async () => {
	const W = { x: 200, y: 300, width: 800, height: 500 };
	const horizontal = (text, y, area = 0) => ({ area, chars: [...text].map((c, i) => [c, 40 + i * 40, y, 40, 40]) });
	const vertical = (text, x, area = 0) => ({ area, vertical: true, chars: [...text].map((c, i) => [c, x, 40 + i * 40, 40, 40]) });
	const setSettings = async (partial) => native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ...partial }) });
	const sendLine = async (line) => {
		await native('http', { url: 'http://127.0.0.1:59881/', body: JSON.stringify(line), timeout: 5 });
		await wait(500);
	};
	const start = async (name, lines, expected, provisional = false) => {
		window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines, provisional });
		await wait(500);
		await gamepadPress(['Button A'], { after: 100 });
		const text = document.querySelector('#ocr-text').textContent.replace(/\n/g, ' / ');
		equal(boxText('gamepad') || boxText('scan'), expected, `${name}: starts at (text "${text}")`);
		await gamepadPress(['Button A'], { after: 300 });
	};
	const appearing = async (top) => {
		const [two, down] = top ? ['明', '明'] : ['今', '今'];
		await start(`${top ? 'top' : 'bottom'}, appearing: two paragraphs`, [horizontal('明日も晴れる', 60), horizontal('今日は雨だ', 300)], two, true);
		await start(`${top ? 'top' : 'bottom'}, appearing: vertical`, [vertical('明日も晴れる', 600), vertical('今日は雨だ', 200)], down, true);
	};

	await wait(2000);
	await until('the WebSocket connection', async () => (await mockLog()).some((l) => l.startsWith('websocket-connected')), 15000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	await appearing(false);
	await setSettings({ gamepadOcrStart: 'top' });
	await wait(300);
	await appearing(true);
	await setSettings({ gamepadOcrStart: 'bottom' });
	await wait(300);
	await start('two paragraphs', [horizontal('明日も晴れる', 60), horizontal('今日は雨だ', 300)], '明');
	await start('bottom one in another area', [horizontal('明日も晴れる', 60), horizontal('今日は雨だ', 300, 1)], '明');
	await start('vertical', [vertical('明日も晴れる', 600), vertical('今日は雨だ', 200)], '明');
	await start('vertical, left one in another area', [vertical('明日も晴れる', 600), vertical('今日は雨だ', 200, 1)], '明');
	window.__macpopupOcr({ type: 'result', width: W.width, height: W.height, lines: [horizontal('雨が降る。', 60)] });
	await wait(500);
	await start('a sentence more on the row', [horizontal('雨が降る。風も吹く', 60)], '風');
	await start('a sentence more, appearing', [horizontal('雨が降る。風も吹く。雪', 60)], '雨', true);
	await sendLine('今日は雨だ');
	await sendLine('明日も晴れる');
	await start('WebSocket: latest on top', [horizontal('明日も晴れる', 60), horizontal('今日は雨だ', 300)], '明');
	await sendLine('今日は雨だ');
	await start('WebSocket: latest at the bottom', [horizontal('明日も晴れる', 60), horizontal('今日は雨だ', 300)], '今');
	await sendLine('風も吹くよ');
	await start('WebSocket: a name row above', [horizontal('太郎さん', 60), horizontal('風も吹くよ', 120)], '風');
	window.__macpopupOcr({ type: 'window', visible: false });
});
