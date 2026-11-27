// "Skip all duplicate lines" past the text box's cap: with "Maximum lines kept" 0 (texthooker-ui's "unlimited") the box
// keeps 1000 lines, but lines dropped past them are still remembered, so one doesn't come back; with a limit set (1000
// too) the lines dropped are forgotten, as before, so it can.
// settings: {"maxLines": 0, "preventGlobalDuplicate": true, "preventLastDuplicate": 0, "mergeEqualLineStarts": false, "clipboardMonitor": false, "ankiEnabled": false}

const shownTexts = () => [...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent);
const lines = Array.from({ length: 1001 }, (_, n) => ({ text: `${n}行目の台詞。`, time: n }));

async function setMaxLines(maxLines) {
	const settings = JSON.parse(await native('getSettings'));
	await native('setSettings', { json: JSON.stringify({ ...settings, maxLines }) });
}

test('overlay', async () => {
	window.__macpopupSetLines(lines);
	await until('1000 lines shown', () => shownTexts().length === 1000);
	equal(shownTexts()[0], '1行目の台詞。', 'the oldest of 1001 left out');

	window.__macpopupClipboard('0行目の台詞。');
	window.__macpopupClipboard('新しい行。');
	await lineWith('新しい行。');
	equal(shownTexts().slice(-2), ['1000行目の台詞。', '新しい行。'], 'with 0, a line dropped past 1000 isn’t added again');

	await setMaxLines(1000);
	window.__macpopupSetLines(lines);
	await until('1000 lines shown again', () => shownTexts().length === 1000 && shownTexts()[999] === '1000行目の台詞。');
	window.__macpopupClipboard('0行目の台詞。');
	await lineWith('0行目の台詞。');
	equal(shownTexts().at(-1), '0行目の台詞。', 'with a limit of 1000, a line dropped past it can come back');
});
