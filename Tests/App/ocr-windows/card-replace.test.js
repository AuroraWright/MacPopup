// A card added from the OCR overlay with text replacements (windows/shotbuf.swift's line, a popup on 晴, its add button):
// the overlay shows the text as read, and the card's sentence has the replacements, as a text box line's would, with
// the cloze still on the word (2026-11-24: before, cards from the overlay had the sentence as read), each entry's on what
// it matched (the second entry, MOCK_SHORT_ENTRY, on 晴 alone).
// mock: MOCK_RUN_FILES=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444 MOCK_CLOZE=1 MOCK_SHORT_ENTRY=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "shotbuf", "title": "ShotTest"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "scanModifier": "none", "replacements": [{"pattern": "明日も", "replaces": "あしたも", "flags": [], "enabled": true}, {"pattern": "いいね", "replaces": "いいな", "flags": [], "enabled": true}], "ankiEnabled": true, "ankiRenderTemplatesLocally": true, "checkForDuplicates": false, "duplicateBehavior": "new", "sentenceAudioEnabled": false, "screenshotFormat": "jpeg", "screenshotQuality": 70, "screenshotResolution": "1x", "screenshotHistory": 0, "screenshotDelay": 1000}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/shotbuf.swift")" ShotTest
// timeout: 120

test('overlay', async () => {
	const line = '明日も晴れるといいね、まだ誰も知らない世界が広がっている。';
	await windowStep('line shown, blue', 90000);
	await until('the line read', () => ocrText().replace(/\n/g, '') === line, 10000).catch(() => {});
	equal(ocrText().replace(/\n/g, ''), line, 'the overlay\'s text, as read');
	// (The window turns red and the line moves 4 points: looked up once it's read again there.)
	await windowStep('red, line moved', 15000);
	await wait(3000);

	const index = ocrText().indexOf('晴');
	expect(index >= 0, '晴 in the text shown');
	const walker = document.createTreeWalker(document.querySelector('#ocr-text'), NodeFilter.SHOW_TEXT);
	let left = index, rect = null;
	for (let node = walker.nextNode(); node && !rect; node = walker.nextNode()) {
		if (left < node.length) {
			const range = document.createRange();
			range.setStart(node, left);
			range.setEnd(node, left + 1);
			rect = range.getBoundingClientRect();
		} else left -= node.length;
	}
	await native('debugMouse', center(rect));
	const button = await until('the add button', () => {
		const found = popupDocument()?.querySelector('.entry .action-button[data-action=save-note]');
		return found && !found.disabled && found;
	}, 10000);
	button.dispatchEvent(new (button.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true }));
	// mock.py's lines "anki <ms> <action> <params>".
	const requests = async (action) => (await mockLog()).map((l) => l.match(/^anki \d+ (\S+) (.*)$/))
		.filter((m) => m?.[1] === action).map((m) => JSON.parse(m[2]));
	const note = await until('the card added', async () => (await requests('addNote'))[0]?.note, 15000);
	log(`fields: ${JSON.stringify(note.fields)}`);
	equal(note.fields.Sentence, 'あしたも晴れるといいな、まだ誰も知らない世界が広がっている。', 'the card\'s sentence');
	equal(note.fields.Cloze, 'あしたも|晴れ|るといいな、まだ誰も知らない世界が広がっている。', 'the cloze (on 晴れ, the dictionary\'s match)');
	// The second entry's card, on 晴 alone.
	const second = popupDocument()?.querySelectorAll('.entry')[1]?.querySelector('.action-button[data-action=save-note]');
	expect(second && !second.disabled, 'the second entry\'s add button');
	if (second) {
		second.dispatchEvent(new (second.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true }));
		const short = await until('the second card added', async () => (await requests('addNote'))[1]?.note, 15000);
		equal(short.fields.Cloze, 'あしたも|晴|れるといいな、まだ誰も知らない世界が広がっている。', 'the second entry\'s cloze (on 晴)');
	}
	equal(ocrText().replace(/\n/g, ''), line, 'the overlay\'s text afterwards');
});
