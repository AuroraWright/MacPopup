// "Keep lines after quitting" with 2000 saved lines (lines.json in the run folder): they're all shown at launch, but
// only those near the box's view are tokenized (furigana), newest first, and the box stays at its end as they grow
// taller with them. A new line is tokenized and shown at the end as usual, and the oldest lines are tokenized once
// they're scrolled to.
// mock: MOCK_TOKENIZE=words
// settings: {"floatingWindowKeepLines": true, "maxLines": 0, "showFurigana": true, "clipboardMonitor": false, "ankiEnabled": false}
// setup: python3 -I -c 'import json, sys; json.dump({"format": "macpopup-lines", "version": "test", "lines": [{"text": f"{n}行目の漢字が入った台詞。", "time": "2026-11-26T10:00:00Z"} for n in range(2000)]}, open(sys.argv[1], "w"), ensure_ascii=False)' "$RUN/lines.json"

const linesElement = document.querySelector('#lines');
const rows = () => [...document.querySelectorAll('#lines p[data-line-id]')];
const hasFurigana = (row) => !!row?.querySelector('ruby');
const atEnd = () => linesElement.scrollTop + linesElement.clientHeight >= linesElement.scrollHeight - 2;
const tokenizeRequests = async () => (await mockLog()).filter((l) => /^yomitan \d+ tokenize$/.test(l)).length;

test('overlay', async () => {
	await until('the saved lines', () => rows().length === 2000);
	await until('the newest saved line tokenized', () => hasFurigana(rows().at(-1)));
	// Until the lines near the view are done.
	let requests = -1;
	await until('tokenizing settled', async () => {
		const now = await tokenizeRequests();
		const settled = now === requests;
		requests = now;
		if (!settled) await wait(500);
		return settled;
	}, 20000);
	expect(requests > 0 && requests < 200, `only the lines near the view tokenized: ${requests} requests for 2000 lines`);
	expect(!hasFurigana(rows()[0]), 'the oldest line isn’t tokenized yet');
	expect(atEnd(), 'the box still at its end');

	window.__macpopupClipboard('新しい行。');
	await lineWith('新しい行。');
	await until('the new line tokenized', () => hasFurigana(rows().at(-1)));
	await wait(200);
	expect(atEnd(), 'the box at its end after the new line');

	linesElement.scrollTop = 0;
	await until('the oldest line tokenized once scrolled to', () => hasFurigana(rows()[0]));
});
