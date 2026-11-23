// Lines dropped from the text box cancel their tokenize: with "maxLines": 2, 8 WebSocket lines 0.3 s apart while
// Yomitan takes 3 s a tokenize, the app's Yomitan API host hands it lines 1-4 at once (its 4 places), lines 5 and 6 wait
// their turn and are dropped by the time a place is free (their requests cancelled, so the host lets them go), and only
// 7 and 8 reach Yomitan after the first four. The driver runs the host with a fake Yomitan and checks what reached it.
// mock: MOCK_WEBSOCKET=1
// settings: {"websocketUrls": ["ws://127.0.0.1:59880"], "yomitanApiUrl": "http://127.0.0.1:59883", "maxLines": 2}
// driver: python3 -I "$REPO/Tests/App/yomitan-api/cancel-driver.py"
// timeout: 90

test('overlay', async () => {
	await until('the WebSocket connected', () => document.querySelector('#socket-icons > .text-green-700'), 15000);
	await wait(2000);
	const lines = [...'一二三四五六七八'].map((n) => `テスト${n}`);
	for (const line of lines) {
		await native('http', { url: 'http://127.0.0.1:59881/', method: 'POST', body: JSON.stringify(line) });
		await wait(300);
	}
	await lineWith('テスト八');
	await wait(8000);
	equal([...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent), lines.slice(6), 'the lines shown');
});
