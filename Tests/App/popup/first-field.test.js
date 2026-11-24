// Anki's notes for a card format whose fields come with their keys sorted (as from Chrome: Sentence, SentenceAudio,
// Word): duplicates are looked for on the note type's first field (Word, from modelFieldNames), which is asked once for
// several lookups; and a second card format for a note type Anki doesn't have (MOCK_GONE_FORMAT, asked once too)
// doesn't take the first one's note buttons away, nor looks for duplicates without a field.
// mock: MOCK_EDITOR=closed MOCK_GONE_FORMAT=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "ankiEnabled": true, "checkForDuplicates": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	const doc = () => popupDocument();
	for (let i = 0; i < 3; i++) {
		window.__macpopupOutsideClick();
		await native('debugMouse', { x: 2, y: 2 });
		await wait(300);
		// (The mock gives the same entry for any text: a newly rendered one, without the mark set on the last.)
		const entry = () => [...(doc()?.querySelectorAll('.entry') ?? [])].find((e) => !e.dataset.looked);
		await native('debugMouse', center(rangeOf(line, i % 2 ? '明' : '晴').getBoundingClientRect()));
		const buttons = await until(`lookup ${i + 1}'s note buttons for the first card format`,
			() => entry()?.querySelector('.action-button[data-card-format-index="0"]:not(.duplicate-indicator)'), 10000)
			.catch((e) => expect(false, e.message));
		if (!buttons) return;
		entry().dataset.looked = '1';
	}
	// mock.py's lines "anki <ms> <action> <params>".
	const anki = (await mockLog()).map((l) => l.match(/^anki (\d+) (\S+) (.*)$/)).filter(Boolean)
		.map(([, time, action, params]) => ({ time: Number(time), action, params: JSON.parse(params) }));
	// (Not for the card format without a first field: an empty query would find every note.)
	const queries = anki.filter((r) => r.action === 'multi').flatMap((r) => r.params.actions)
		.filter((a) => a.action === 'findNotes').map((a) => a.params.query);
	expect(queries.length > 0 && queries.every((q) => /"word:/.test(q)), `duplicates looked for on Word only: ${queries.join(' | ')}`);
	// Kept for 10 s (the lookups take about a second each): not asked again sooner, also when Anki doesn't know it.
	const asked = (model) => anki.filter((r) => r.action === 'modelFieldNames' && r.params.modelName === model).map((r) => r.time);
	for (const model of ['Mock', 'Gone']) {
		const times = asked(model);
		const sooner = times.slice(1).filter((time, i) => time - times[i] < 10000).length;
		expect(times.length > 0 && sooner === 0, `${model}'s fields asked for ${times.length} times, ${sooner} within 10 s of the last`);
	}
});
