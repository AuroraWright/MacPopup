// The debug log in OCR Mode (Live Text) on the sparse window (windows/sparse.swift): it starts with a session record
// whose settings have the OCR settings, then an "ocr" record with the window read (owner sparse, title SparseTest,
// bounds, overlay shown), readings; a setting changed (ocrChangeThreshold 0.3 → 0.5) and set back are recorded as two
// settings records with just that setting.
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "sparse", "title": "SparseTest"}, "ocrRegions": [], "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/sparse.swift")" SparseTest
// timeout: 120

test('overlay', async () => {
	await windowStep('shown "第1章"', 90000);
	await until('第1章 read', () => ocrText().includes('第1章'), 10000).catch(() => {});
	const settings = JSON.parse(await native('getSettings'));
	await native('setSettings', { json: JSON.stringify({ ...settings, ocrChangeThreshold: 0.5 }) });
	await wait(2000);
	await native('setSettings', { json: JSON.stringify({ ...settings, ocrChangeThreshold: 0.3 }) });
	await wait(1000);
	const records = await debugRecords();
	log(`record types: ${JSON.stringify(records.map((r) => r.type))}`);
	equal(records[0]?.type, 'session', 'the first record');
	const s = records[0]?.settings ?? {};
	equal([s.ocrMode, s.ocrEngine, s.ocrChangeThreshold, s.ocrWindow], [true, 'liveText', 0.3, { ownerName: 'sparse', title: 'SparseTest' }],
		'the session\'s settings (ocrMode, ocrEngine, ocrChangeThreshold, ocrWindow)');
	const ocr = records.filter((r) => r.type === 'ocr' && r.window?.owner === 'sparse');
	log(`ocr records: ${JSON.stringify(ocr.map((r) => r.window))}`);
	const window = ocr.find((r) => r.window.bounds)?.window;
	equal(window && { owner: window.owner, title: window.title, width: window.bounds[2], overlayShown: window.overlayShown },
		{ owner: 'sparse', title: 'SparseTest', width: 1600, overlayShown: true }, 'the window read, in an "ocr" record');
	const readings = records.filter((r) => r.type === 'reading' && (r.shown ?? []).some((line) => line.text.includes('第1章')));
	expect(readings.length > 0, `readings of 第1章 recorded: ${readings.length}`);
	equal(records.filter((r) => r.type === 'settings').map((r) => r.changed), [{ ocrChangeThreshold: 0.5 }, { ocrChangeThreshold: 0.3 }],
		'the settings records');
});
