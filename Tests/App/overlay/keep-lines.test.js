// "Keep lines after quitting" (SavedLines.swift): the four lines saved before (lines.json in the run folder) come back
// at launch, the oldest left out by "Maximum lines kept" (3), with their times, and count as shown for "Skip all
// duplicate lines". A new line is saved within a few seconds; Import's lines (window.__macpopupSetLines, which
// Settings → Import → Floating Window Lines calls) replace the box's and are saved; turning the setting off deletes the
// file, turning it on again saves what's shown, and clearing the box deletes it again.
// mock: MOCK_RUN_FILES=1
// settings: {"floatingWindowKeepLines": true, "maxLines": 3, "preventGlobalDuplicate": true, "preventLastDuplicate": 0, "mergeEqualLineStarts": false, "clipboardMonitor": false, "ankiEnabled": false}
// setup: printf '%s' '{"format": "macpopup-lines", "version": "test", "lines": [{"text": "一行目", "time": "2026-11-26T10:00:00Z"}, {"text": "二行目", "time": "2026-11-26T10:00:01Z"}, {"text": "三行目", "time": "2026-11-26T10:00:02Z"}, {"text": "四行目", "time": "2026-11-26T10:00:03Z"}]}' > "$RUN/lines.json"

const shownTexts = () => [...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent);

/** The saved file's lines ({text, time}), or null when there's no file. */
async function saved() {
	const text = await runFile('lines.json');
	return text ? JSON.parse(text).lines : null;
}

/** The saved lines' texts once they're `texts` (null: once there's no file). */
function savedAs(texts, what) {
	const want = JSON.stringify(texts);
	return until(what, async () => {
		const lines = await saved();
		return JSON.stringify(lines && lines.map((line) => line.text)) === want && (lines ?? 'none');
	});
}

async function setKeepLines(on) {
	const settings = JSON.parse(await native('getSettings'));
	await native('setSettings', { json: JSON.stringify({ ...settings, floatingWindowKeepLines: on }) });
}

test('overlay', async () => {
	await until('the saved lines', () => shownTexts().length === 3);
	equal(shownTexts(), ['二行目', '三行目', '四行目'], 'the saved lines shown, the oldest left out');

	window.__macpopupClipboard('三行目');
	window.__macpopupClipboard('五行目');
	await lineWith('五行目');
	equal(shownTexts(), ['三行目', '四行目', '五行目'], 'a saved line isn’t added again');
	const lines = await savedAs(['三行目', '四行目', '五行目'], 'the new line saved');
	equal(lines.slice(0, 2).map((line) => line.time), ['2026-11-26T10:00:02Z', '2026-11-26T10:00:03Z'], 'the saved lines keep their times');

	window.__macpopupSetLines([{ text: 'いち', time: 0 }, { text: 'に', time: 1000 }]);
	equal(shownTexts(), ['いち', 'に'], 'imported lines replace the box’s');
	await savedAs(['いち', 'に'], 'the imported lines saved');

	await setKeepLines(false);
	await savedAs(null, 'the file deleted when the setting is turned off');
	equal(shownTexts(), ['いち', 'に'], 'the lines stay shown');
	await setKeepLines(true);
	await savedAs(['いち', 'に'], 'the lines saved when it’s turned on again');

	document.querySelector('#clear-button').click();
	equal(shownTexts(), [], 'the box cleared');
	await savedAs(null, 'the file deleted when the box is cleared');
});
