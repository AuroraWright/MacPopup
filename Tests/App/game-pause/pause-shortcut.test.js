// Game Pause's pause and scan shortcut (window.__macpopupPauseShortcut, what the global shortcut calls: synthetic key
// presses don't reach global shortcuts) in OCR Mode (Live Text) on a line being typed a character every 250 ms
// (ocr-windows/windows/typer.swift): pressed while it's typed, the game's process is stopped (by the pause helper) and the
// part shown then is read and stays; hovering over it opens a popup on it (debugMouse, not the real pointer); pressed
// again, the popup closes, the game goes on, and the whole line is read. The game's process state comes from
// harness/tools/gamestate.py. Without the pause helper (allowed in Settings → Permissions → Pause helper) it fails
// first with "NOT RUN: …".
// It pauses the test window's process (typer, with the pause helper, which runs as root).
// interactive
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// env: MACPOPUP_DEBUG_OCR=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "typer", "title": "TyperTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": true, "ocrMouseWatchTime": 2000, "ocrPollInterval": 100, "ocrShowBoxes": true, "gamePause": true, "gamePauseShortcut": null, "gamepadScanButtons": [], "scanModifier": "none", "clipboardMonitor": false, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/typer.swift")" TyperTest
// driver: python3 -I "$HARNESS/tools/gamestate.py" "$REPO/build/test/tools/typer"
// timeout: 120

/** The state of the game's process at `time` (the last one logged by then), '' when none was. */
async function stateAt(time) {
	return (await processStates()).filter((s) => s.time <= time).at(-1)?.state ?? '';
}

/** The middle of the shown text's `index`th character, in the overlay's points. */
function charAt(index) {
	const walker = document.createTreeWalker(document.querySelector('#ocr-text'), NodeFilter.SHOW_TEXT);
	let left = index;
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		if (left < node.length) {
			const range = document.createRange();
			range.setStart(node, left);
			range.setEnd(node, left + 1);
			return center(range.getBoundingClientRect());
		}
		left -= node.length;
	}
	throw new Error(`no character ${index} in the text shown`);
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
	await wait(1500);
	const paused = ocrText().replace(/\n/g, '');
	expect(paused && line.startsWith(paused) && paused.length < line.length, `the text read once paused: "${paused}"`);
	expect((await stateAt(pressed + 1000)).startsWith('T'), `the game stopped 1 s after the press: ${await stateAt(pressed + 1000)}`);

	const at = charAt(1);
	await native('debugMouse', { x: at.x + 7, y: at.y + 5 });
	await wait(100);
	await native('debugMouse', at);
	await until('the popup', () => popupVisible() && boxText('scan'), 5000).catch(() => {});
	const word = boxText('scan');
	expect(popupVisible() && word && paused.includes(word), `hovered: a popup on "${word}" in the text read`);
	await wait(3000);
	equal(ocrText().replace(/\n/g, ''), paused, 'the text 3 s later, still paused');
	equal(popupVisible(), true, 'the popup still open 3 s later');
	const states = (await processStates()).filter((s) => s.time >= pressed + 1000 && s.time <= Date.now() - 200);
	const running = states.filter((s) => !s.state.startsWith('T'));
	expect(states.length > 20 && running.length === 0,
		`the game stayed stopped while paused: running in ${running.length} of ${states.length} checks`);

	const again = Date.now();
	log('press shortcut');
	window.__macpopupPauseShortcut();
	await wait(1000);
	equal(popupVisible(), false, 'pressed again: the popup is open');
	const resumed = await stateAt(again + 1000);
	expect(resumed && !resumed.startsWith('T'), `the game going on 1 s after the second press: ${resumed}`);
	await until('the whole line', () => ocrText().replace(/\n/g, '') === line, 12000).catch(() => {});
	equal(ocrText().replace(/\n/g, ''), line, 'the text within 12 s of the second press');
});
