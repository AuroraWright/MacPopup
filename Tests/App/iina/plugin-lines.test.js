// The IINA plugin's lines: the user's IINA (iina.py; history and recent files off for the run) plays the test video
// muted (20 s, Japanese subtitles at 2–4, 6–8.5 and 11–13 s) with its MacPopup plugin on 6680. iina-lines.py reads the
// plugin's WebSocket as MacPopup does: the three lines with their times, the file and its streams as their video and
// audio, each sent as it's shown, and the window's status each second (subtitles ["jpn"], 20 s, not paused). The box
// shows each line once, in order. From scratch-tools/iina/plugin-run.sh and client.mjs.
// Opens the user's IINA (muted; not while it runs) and quits it; its settings and plugins are checked unchanged.
// interactive
// setup: python3 -I "$REPO/Tests/App/iina/iina.py" setup test
// beside: python3 -I "$REPO/Tests/App/iina/iina.py" beside
// settings: {"websocketUrls": ["ws://127.0.0.1:6680"], "continuousReconnect": true, "showConnectionErrors": false, "iinaTranscribe": false, "ankiEnabled": false}
// driver: python3 -I "$REPO/Tests/App/iina/iina-lines.py"
// timeout: 120

test('overlay', async () => {
	const texts = ['今日はいい天気ですね', '明日も晴れるといいな', '猫が窓の外を見ている'];
	for (const text of texts) await lineWith(text, 90000);
	const shown = [...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent);
	log(`lines: ${JSON.stringify(shown)}`);
	equal(texts.map((text) => shown.filter((s) => s.includes(text)).length), [1, 1, 1], 'each line in the box once');
	equal(texts.map((text) => shown.findIndex((s) => s.includes(text))).every((i, n, all) => n === 0 || i > all[n - 1]), true,
		'in order');
});
