// Game Pause's pause and scan shortcut ends when you switch to another app: pressed (window.__macpopupPauseShortcut)
// while a line is typed in OCR Mode (Live Text, ocr-windows/windows/typer.swift), the game is stopped; once another app
// comes to the front (windows/otherapp.swift, started by "// beside:" when the page logs "switch app"), Game Pause notes
// the switch, the game goes on and the rest of the line is read. ("Only check after input" is off here, so the reading
// goes on by itself after the switch.) Without the pause helper it fails first with "NOT RUN: …".
// It pauses the test window's process (typer, with the pause helper) and brings a test app to the front, taking the
// focus from the app that has it for 6 s.
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// env: MACPOPUP_DEBUG_OCR=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "typer", "title": "TyperTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "gamePause": true, "gamePauseShortcut": null, "gamepadScanButtons": [], "scanModifier": "none", "clipboardMonitor": false, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: o=$("$HARNESS/tools/build.sh" "$REPO/Tests/App/game-pause/windows/otherapp.swift"); "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/typer.swift")" TyperTest & until grep -q 'TEST switch app' "$RUN/app.log" 2>/dev/null; do sleep 0.1; done; "$o" 6
// driver: python3 -I "$HARNESS/tools/gamestate.py" "$REPO/build/test/tools/typer"
// timeout: 120

/** The state of the game's process at `time` (the last one logged by then), '' when none was. */
async function stateAt(time) {
	return (await processStates()).filter((s) => s.time <= time).at(-1)?.state ?? '';
}

test('overlay', async () => {
	const line = '扉の向こうに、まだ誰も知らない世界が広がっているんだよ。';
	const sent = await windowStep('line sent', 90000);
	const first = await until('the first text', () => ocrText(), 10000).catch(() => '');
	expect(first && line.startsWith(first.replace(/\n/g, '')) && first.length < line.length,
		`the line's start shown while it's typed: "${first}" after ${Date.now() - sent} ms`);
	await wait(300);
	const before = (await gamePauseNotes()).length;
	const pressed = Date.now();
	log('press shortcut');
	window.__macpopupPauseShortcut();
	const note = await until('Game Pause\'s note', async () => (await gamePauseNotes())[before], 5000).catch(() => '');
	if (!note?.startsWith('game paused')) {
		expect(false, `NOT RUN: the game wasn't paused, so nothing else is checked: ${note || 'no note from Game Pause'}` +
			' (the pause helper needs allowing in Settings → Permissions → Pause helper, and launchd must start it)');
		return;
	}
	log(`Game Pause: ${note}`);
	await wait(3000);
	const paused = ocrText().replace(/\n/g, '');
	expect(paused && line.startsWith(paused) && paused.length < line.length, `the text read once paused: "${paused}"`);
	const stopped = await stateAt(Date.now() - 200);
	expect(stopped.startsWith('T') && (await stateAt(pressed + 1000)).startsWith('T'), `the game stopped before the switch: ${stopped}`);

	log('switch app');
	const active = await windowStep('active', 10000).catch(() => 0);
	expect(active > 0, 'the other app came to the front');
	if (!active) return;
	await wait(1500);
	const switched = (await gamePauseNotes()).slice(before).find((n) => n.startsWith('switched to '));
	expect(!!switched, `Game Pause noted the switch: ${switched}`);
	const going = await stateAt(active + 1500);
	expect(going && !going.startsWith('T'), `the game going on 1.5 s after the switch: ${going}`);
	await until('more of the line', () => ocrText().replace(/\n/g, '').length > paused.length, 5000).catch(() => {});
	expect(ocrText().replace(/\n/g, '').length > paused.length, `more of the line read within 5 s of the switch: "${ocrText()}"`);
	await until('the whole line', () => ocrText().replace(/\n/g, '') === line, 12000).catch(() => {});
	equal(ocrText().replace(/\n/g, ''), line, 'the text within 12 s of the switch');
});
