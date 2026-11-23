// Sentence audio for a card open in Anki's card browser (MOCK_EDITOR=browser: note 333 selected there, and AnkiConnect
// refuses to change a note open in an editor): the recording (the test file, played as the game's audio) is stored,
// then the browser is cleared (guiBrowse nid:1), the note's SentenceAudio field updated without an error, and the note
// shown in the browser again (guiBrowse nid:333). No error message is shown.
// mock: MOCK_EDITOR=browser
// setup: say -v Kyoko -o "$RUN/voice.aiff" 明日も晴れるといいね
// env: MACPOPUP_TEST_AUDIO_FILE=$RUN/voice.aiff
// settings: {"ankiEnabled": true, "sentenceAudioEnabled": true, "sentenceAudioField": "SentenceAudio", "sentenceAudioApp": "none", "sentenceAudioPlay": false}
// timeout: 90

test('overlay', async () => {
	const toasts = [];
	const toast = await until('the toast function', () => window.__macpopupToast);
	window.__macpopupToast = (...args) => {
		toasts.push(String(args[0]));
		return toast(...args);
	};
	await wait(1000);
	// The card from a popup (as an Option-click on its add button passes it).
	await native('debugSentenceAudio', { note: 333 });
	const actions = async () => (await mockLog()).filter((l) => /^anki \d+ (notesInfo|storeMediaFile|guiSelectedNotes|guiBrowse|updateNoteFields) /.test(l))
		.map((l) => l.replace(/^anki \d+ /, ''));
	await until('the note shown in the browser again', async () => (await actions()).some((a) => a.startsWith('guiBrowse') && a.includes('nid:333')), 60000)
		.catch((e) => expect(false, e.message));
	await wait(500);
	const done = await actions();
	const names = done.map((a) => a.split(' ')[0] + (a.startsWith('guiBrowse') ? ` ${JSON.parse(a.slice(a.indexOf(' ') + 1)).query}` : ''));
	equal(names, ['notesInfo', 'storeMediaFile', 'guiSelectedNotes', 'guiBrowse nid:1', 'updateNoteFields', 'guiBrowse nid:333'], 'AnkiConnect calls');
	const store = JSON.parse(done.find((a) => a.startsWith('storeMediaFile'))?.replace(/^\S+ /, '') ?? '{}');
	expect(/^macpopup-sentence-.*\.m4a$/.test(store.filename) && store.data?.length > 1000,
		`the recording stored: ${store.filename}, ${store.data?.length} base64 characters`);
	const update = JSON.parse(done.find((a) => a.startsWith('updateNoteFields'))?.replace(/^\S+ /, '') ?? '{}');
	// (Separately: the host's JSON keys come in any order.)
	equal([update.note?.id, update.note?.fields], [333, { SentenceAudio: `[sound:${store.filename}]` }], 'the note\'s update');
	const replies = (await mockLog()).filter((l) => l.startsWith('anki-reply updateNoteFields '));
	equal(replies.map((l) => JSON.parse(l.replace(/^anki-reply updateNoteFields /, '')).error), [null], 'updateNoteFields errors');
	const errors = toasts.filter((t) => /Couldn|No |Close|error|isn’t|already/i.test(t));
	equal(errors, [], `error messages (messages: ${toasts.join(' | ')})`);
});
