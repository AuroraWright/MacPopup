// Anki's notes for a card format whose fields come with their keys sorted (as from Chrome: Sentence, SentenceAudio,
// Word): duplicates are looked for on the note type's first field (Word, from modelFieldNames), which is asked once for
// several lookups; and a second card format for a note type Anki doesn't have (MOCK_GONE_FORMAT) doesn't take the
// first one's note buttons away.
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
	const anki = (await mockLog()).filter((l) => /^anki \d+ /.test(l)).map((l) => l.replace(/^anki \d+ /, ''));
	const queries = anki.filter((l) => l.startsWith('multi ')).flatMap((l) => JSON.parse(l.slice(6)).actions.map((a) => a.params?.query)).filter(Boolean);
	expect(queries.length > 0 && queries.every((q) => /"word:/.test(q)), `duplicates looked for on Word: ${queries.join(' | ')}`);
	const asked = (model) => anki.filter((l) => l.startsWith('modelFieldNames ') && l.includes(`"${model}"`)).length;
	equal(asked('Mock'), 1, 'the note type\'s fields asked for in 3 lookups');
	expect(asked('Gone') >= 1, `the missing note type's fields asked for (${asked('Gone')} times)`);
});
