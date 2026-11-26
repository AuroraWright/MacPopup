// The debug log's records (debug.jsonl, Settings → General → Debug, i.e. ocrShowBoxes): turning Debug off deletes the
// log, and on again starts a new one with a session record and the connections; then, with one popup shortcut "Add note
// (sentence audio)" on Alt+J and Button X: a lookup of 晴 ("popup shown"), Button Y with a popup open ("no popup
// shortcut for these buttons"), Button X ("popup shortcut" from the controller, "card added" note 444, Anki Audio's
// log line and its message), a setting changed (scanDelay 37), the popup closed, and Button X without a popup (the
// game's: nothing logged).
// mock: MOCK_EDITOR=closed MOCK_ADD_NOTE=444 MOCK_RUN_FILES=1
// clipboard: 明日も晴れるといいね
// settings: {"ocrShowBoxes": true, "clipboardMonitor": true, "ankiEnabled": true, "ankiRenderTemplatesLocally": true, "checkForDuplicates": false, "duplicateBehavior": "new", "sentenceAudioEnabled": true, "sentenceAudioHistory": 0, "sentenceAudioBacklog": false, "sentenceAudioField": "SentenceAudio", "screenshotHistory": 0, "gamePause": false, "scanDelay": 20, "hotkeys": [{"action": "addNoteSentenceAudio", "argument": "0", "key": "KeyJ", "modifiers": ["alt"], "buttons": ["Button X"], "enabled": true}]}
// timeout: 60

test('overlay', async () => {
	const setSettings = async (partial) => native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ...partial }) });
	await wait(1000);
	await setSettings({ ocrShowBoxes: false });
	await wait(1000);
	equal(await runFile('debug.jsonl'), '', 'Debug off: the log is deleted');
	await setSettings({ ocrShowBoxes: true });
	await wait(1000);

	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	await until('the add button', () => {
		const found = popupDocument()?.querySelector('.entry .action-button[data-action=save-note]');
		return found && !found.disabled && found;
	});
	await gamepadPress(['Button Y'], { after: 300 });
	await gamepadPress(['Button X'], { after: 3500 });
	await setSettings({ scanDelay: 37 });
	await wait(500);
	window.macpopupOverlay.closePopup(0);
	await wait(500);
	await gamepadPress(['Button X'], { after: 1000 });

	const records = await debugRecords();
	const types = records.map((r) => r.type);
	equal(types[0], 'session', 'the new log\'s first record');
	equal(types.filter((t) => t === 'session').length, 1, 'session records');
	const connections = records.find((r) => r.type === 'connections');
	equal(connections && { anki: connections.anki, yomitanApi: connections.yomitanApi },
		{ anki: 'Connected (AnkiConnect v6)', yomitanApi: 'Connected (Yomitan mock)' }, 'the connections');
	// The events and Anki Audio's log lines, in order, without their times.
	const steps = records.flatMap((r) => {
		if (r.type === 'event') {
			const { type, time, ...rest } = r;
			return [rest];
		}
		if (r.type === 'settings') return [{ settings: r.changed }];
		if (r.type === 'log' && r.message.startsWith('anki audio:')) return [{ log: r.message }];
		return [];
	});
	const kept = 'Game audio isn’t being kept. Turn on “Keep game audio for the last” in Settings → Anki Audio.';
	const find = (match) => steps.findIndex((s) => Object.entries(match).every(([k, v]) => JSON.stringify(s[k]) === JSON.stringify(v)));
	const order = [
		{ event: 'popup shown', depth: 0, lookup: 'term', query: '晴れ', entries: 150 },
		{ event: 'controller: no popup shortcut for these buttons', buttons: ['Button Y'] },
		{ event: 'popup shortcut', action: 'addNoteSentenceAudio', argument: '0', from: 'controller', popups: 1 },
		{ event: 'card added', note: 444, format: 'Mock', overwritten: false, depth: 0, query: '晴れ', nested: false, voice: 'asked for' },
		{ log: `anki audio: history: ${kept}` },
		{ event: 'message shown', message: kept },
		{ settings: { scanDelay: 37 } },
		{ event: 'popup closed', depth: 0 },
	];
	const at = order.map(find);
	equal(at.map((i) => i >= 0), order.map(() => true), `the records found (${order.map((o) => o.event ?? Object.keys(o)[0]).join('; ')})`);
	expect(at.every((i, n) => n === 0 || i > at[n - 1]), `in that order (at ${at.join(', ')})`);
	const after = steps.slice(at.at(-1) + 1);
	equal(after, [], 'records after the popup closed (Button X without a popup)');
	equal(steps.filter((s) => s.event === 'popup shortcut').length, 1, 'popup shortcuts');
});
