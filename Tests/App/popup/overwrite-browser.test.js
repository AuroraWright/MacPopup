// Overwriting a card open in Anki's card browser (MOCK_EDITOR=browser: the word's note 333 exists and is selected there,
// and AnkiConnect refuses to change a note open in an editor), with duplicateBehavior overwrite: the first entry's add
// button offers Overwrite; clicking it clears the browser (guiBrowse nid:1), updates note 333 without an error, and
// shows the note in the browser again (guiBrowse nid:333). The popup shows no error. (The note's fields are rendered
// locally: the mock's ankiFields has no field values, and a note with an empty first field can't be added.)
// mock: MOCK_EDITOR=browser
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "ankiEnabled": true, "checkForDuplicates": true, "duplicateBehavior": "overwrite", "ankiRenderTemplatesLocally": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const doc = () => popupDocument();
	const button = await until('the Overwrite button', () => {
		const found = doc()?.querySelector('.entry .action-button[data-action=save-note]');
		return found?.dataset.overwrite && !found.disabled && found;
	});
	expect(/overwrite/i.test(button.title), `the add button's title: ${JSON.stringify(button.title)}`);
	const before = (await mockLog()).length;
	button.click();
	const actions = async () => (await mockLog()).slice(before).filter((l) => /^anki \d+ (guiSelectedNotes|guiBrowse|updateNoteFields|addNote) /.test(l))
		.map((l) => l.replace(/^anki \d+ /, ''));
	await until('the note shown in the browser again', async () => (await actions()).some((a) => a.startsWith('guiBrowse') && a.includes('nid:333')), 15000)
		.catch((e) => expect(false, e.message));
	await wait(1500);
	const done = await actions();
	const names = done.map((a) => a.split(' ')[0] + (a.startsWith('guiBrowse') ? ` ${JSON.parse(a.slice(a.indexOf(' ') + 1)).query}` : ''));
	equal(names, ['guiSelectedNotes', 'guiBrowse nid:1', 'updateNoteFields', 'guiBrowse nid:333'], 'AnkiConnect calls after the click');
	const update = JSON.parse(done.find((a) => a.startsWith('updateNoteFields'))?.replace(/^\S+ /, '') ?? '{}');
	equal(update.note?.id, 333, 'the note updated');
	const replies = (await mockLog()).filter((l) => l.startsWith('anki-reply updateNoteFields '));
	equal(replies.map((l) => JSON.parse(l.replace(/^anki-reply updateNoteFields /, '')).error), [null], 'updateNoteFields errors');
	const notification = [...doc().querySelectorAll('.footer-notification:not([hidden])')].map((n) => n.textContent.trim()).filter(Boolean);
	equal(notification, [], 'the popup\'s notifications after');
});
