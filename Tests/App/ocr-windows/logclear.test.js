// The debug log in OCR Mode (Live Text) on the sparse window (windows/sparse.swift), turned off and on: while on, it has
// the session record first and the OCR records (the window, readings); turned off (ocrShowBoxes false), it's deleted;
// turned on again, a new log starts with a session record, then an "ocr" record with the window read, and readings go
// on into it. (overlay/debuglog checks the same without OCR.)
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "sparse", "title": "SparseTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/sparse.swift")" SparseTest
// timeout: 120

test('overlay', async () => {
	const set = async (on) => native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ocrShowBoxes: on }) });
	const types = (records) => records.map((r) => r.type);
	await windowStep('shown "第1章"', 90000);
	await until('第1章 read', () => ocrText().includes('第1章'), 10000).catch(() => {});
	await wait(1000);
	const on = await debugRecords();
	log(`on: ${JSON.stringify(types(on))}`);
	equal(on[0]?.type, 'session', 'on: the first record');
	expect(types(on).includes('ocr') && types(on).includes('reading'), 'on: "ocr" and "reading" records');

	await set(false);
	await wait(1500);
	equal(await runFile('debug.jsonl'), '', 'off: the log is deleted');

	await set(true);
	await wait(1500);
	const again = await debugRecords();
	log(`on again: ${JSON.stringify(types(again))}`);
	equal(types(again).filter((t) => t !== 'connections' && t !== 'log').slice(0, 2), ['session', 'ocr'], 'on again: the first records (but connections and messages)');
	equal(again.find((r) => r.type === 'ocr')?.window?.owner, 'sparse', 'on again: the window read');
	equal(again.filter((r) => r.type === 'session').length, 1, 'on again: session records');
	// The window shows nothing from 25 s, then a line from 28 s: read into the new log.
	await windowStep('shown "“視線', 30000);
	await until('the line read', () => ocrText().includes('視線'), 10000).catch(() => {});
	await wait(1000);
	const later = await debugRecords();
	expect(later.some((r) => r.type === 'reading' && (r.shown ?? []).some((line) => line.text.includes('視線'))), 'on again: the line\'s readings recorded');
	equal(later[0]?.type, 'session', 'on again: still the first record');
});
