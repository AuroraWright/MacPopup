// shotbuf with an Option-click on the popup's add button: Anki Screenshot's kept screenshots in OCR Mode (Live Text) on
// windows/shotbuf.swift: a line shown on blue, then the window turns red and the line moves 4 points, so OCR reads the
// same line again. A card added from it after that gets the line's own screenshot, the blue one.
// mock: MOCK_RUN_FILES=1 MOCK_EDITOR=closed MOCK_ADD_NOTE=444 MOCK_SHOT=1
// settings: {"ocrMode": true, "ocrEngine": "liveText", "ocrCloudEngine": "none", "ocrWindow": {"ownerName": "shotbuf", "title": "ShotTest"}, "ocrRegions": [], "ocrUseWebsocket": false, "ocrMouseWatch": false, "ocrPollInterval": 100, "ocrShowBoxes": true, "scanModifier": "none", "ankiEnabled": true, "ankiRenderTemplatesLocally": true, "checkForDuplicates": false, "duplicateBehavior": "new", "sentenceAudioEnabled": false, "screenshotFormat": "jpeg", "screenshotQuality": 70, "screenshotResolution": "1x", "screenshotHistory": 20, "screenshotDelay": 1000}
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/shotbuf.swift")" ShotTest
// timeout: 120

test('overlay', async () => {
	const line = '明日も晴れるといいね、まだ誰も知らない世界が広がっている。';
	const blue = await windowStep('line shown, blue', 90000);
	await until('the line read', () => ocrText().replace(/\n/g, '') === line, 10000).catch(() => {});
	equal(ocrText().replace(/\n/g, ''), line, 'the line read on blue');
	const red = await windowStep('red, line moved', 15000);
	await wait(4000);
	const messages = (await debugRecords()).filter((r) => r.type === 'log').map((r) => ({ time: Date.parse(r.time), message: r.message }));
	const lineNotes = messages.filter((m) => m.time > blue && /^line \d+ /.test(m.message)).map((m) => [m.time > red ? 'red' : 'blue', m.message]);
	log(`lines noted: ${JSON.stringify(lineNotes)}`);
	expect(lineNotes.some(([when, message]) => when === 'red' && /again|grew/.test(message)), 'the moved line read again on red, as the same line');

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
	button.dispatchEvent(new (button.ownerDocument.defaultView.MouseEvent)('click', { bubbles: true, cancelable: true, altKey: true }));
	// mock.py's lines "anki <ms> <action> <params>".
	const requests = async (action) => (await mockLog()).map((l) => l.match(/^anki \d+ (\S+) (.*)$/))
		.filter((m) => m?.[1] === action).map((m) => JSON.parse(m[2]));
	const stored = await until('the screenshot stored',
		async () => (await requests('storeMediaFile')).find((params) => /screenshot/.test(params.filename ?? '')), 15000);
	log(`stored ${stored.filename}, ${stored.data?.length} base64 characters`);
	const image = new Image();
	image.src = `data:image/jpeg;base64,${stored.data}`;
	await image.decode();
	const canvas = document.createElement('canvas');
	canvas.width = image.width;
	canvas.height = image.height;
	const context = canvas.getContext('2d');
	context.drawImage(image, 0, 0);
	const [r, g, b] = context.getImageData(40, 40, 1, 1).data;
	log(`the screenshot: ${image.width}x${image.height}, at 40,40 rgb(${r}, ${g}, ${b})`);
	equal(b > r ? 'blue' : 'red', 'blue', `the card's screenshot (rgb(${r}, ${g}, ${b}) at 40,40)`);
	equal((await requests('addNote')).length, 1, 'cards added');
});
