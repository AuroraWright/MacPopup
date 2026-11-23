// OCR Mode (Live Text, WebSocket lines) on a window that covers itself with a window of its own at times
// (windows/cover.swift): a line shown while it's entirely covered, or covered but for a 2% strip, is read only once it's
// uncovered (within 5 s), and a line shown while it's half covered, or not at all, at once (within 5 s). The window is
// logged as unavailable ("covered by other windows") once covered, and its capture stream stops within 3 s.
// (2026-11-15: before the fix every line was read at once, covered or not.)
// mock: MOCK_RUN_FILES=1 MOCK_WEBSOCKET=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "cover", "title": "CoverTest"}, "ocrRegions": [], "websocketUrls": ["ws://127.0.0.1:59880"], "ocrUseWebsocket": true, "ocrMouseWatch": false, "ocrChangeThreshold": 0.3, "ocrPollInterval": 100, "ocrShowBoxes": true, "screenshotHistory": 0, "ankiEnabled": false, "sentenceAudioEnabled": false}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/cover.swift")"
// timeout: 150

test('overlay', async () => {
	const lines = {
		A: '扉の向こうに、まだ誰も知らない世界が広がっている。',
		B: '風が止んだ瞬間、街の灯りが一斉に消えた。',
		C: '彼女は黙って古い地図を広げ、指で川をなぞった。',
		D: '約束の時間を過ぎても、駅には誰も来なかった。',
	};
	const texts = watch(() => ocrText().replace(/\n/g, ''));
	const start = await windowStep('start', 90000);
	await until('the window quitting', () => Date.now() > start + 58000, 70000);
	texts.stop();
	log(`texts: ${JSON.stringify(texts.map((t) => [t.time - start, t.value]))}`);
	const steps = await windowSteps();
	const step = (name) => steps.find((s) => s.step === name)?.time;
	const covers = steps.filter((s) => s.step.startsWith('cover ')).map((s) => [s.time - start, s.step]);
	log(`window steps: ${JSON.stringify(steps.map((s) => [s.time - start, s.step]))}`);
	equal(covers.map(([, s]) => s), ['cover all', 'cover none', 'cover left half', 'cover none', 'cover all but 2%', 'cover none'], 'the window\'s covers');
	const shownAt = (text, from) => texts.find((t) => t.time >= from && t.value === text)?.time;
	// [line, when it's shown, from when it should be read]
	const cases = [
		['A', step(`line ${lines.A}`), step(`line ${lines.A}`)],
		['B', step(`line ${lines.B}`), steps.filter((s) => s.step === 'cover none')[0]?.time],
		['C', step(`line ${lines.C}`), step(`line ${lines.C}`)],
		['D', step(`line ${lines.D}`), steps.filter((s) => s.step === 'cover none')[2]?.time],
	];
	for (const [name, shown, readable] of cases) {
		const at = shownAt(lines[name], shown);
		expect(at !== undefined && at >= readable && at - readable < 5000,
			`line ${name} shown ${at === undefined ? 'never' : `${at - shown} ms after it came`}, `
			+ `${readable === shown ? 'at once' : `once uncovered (${readable - shown} ms after it came)`} within 5 s`);
	}
	const messages = (await debugRecords()).filter((r) => r.type === 'log').map((r) => ({ time: Date.parse(r.time), message: r.message }));
	log(`messages: ${JSON.stringify(messages.filter((m) => /unavailable|available again|stream/.test(m.message)).map((m) => [m.time - start, m.message]))}`);
	const coverAll = step('cover all');
	const unavailable = messages.find((m) => m.time > coverAll && /^window unavailable: covered by other windows/.test(m.message));
	expect(unavailable && unavailable.time - coverAll < 2000,
		`covered entirely: unavailable within 2 s (${unavailable ? `${unavailable.time - coverAll} ms: ${unavailable.message}` : 'never'})`);
	const stopped = messages.find((m) => m.time > coverAll && /stream (stopped|ended)/.test(m.message));
	expect(stopped && stopped.time - coverAll < 3000,
		`covered entirely: the capture stream stopped within 3 s (${stopped ? `${stopped.time - coverAll} ms: ${stopped.message}` : 'never'})`);
});
