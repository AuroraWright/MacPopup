// "Add note (sentence audio)" from a controller and from the keyboard: one popup shortcut with that action, on Alt+J
// and Button X. With a popup open on 晴, pressing Button X and then the keyboard shortcut (__macpopupHotkey(0)) each
// add a note (AnkiConnect's addNote, note 444) and reach Anki Audio, which only says why it can't take the voice (no
// game audio recorded, no backlog): the app log's "[sentence audio]" lines, for each note: the card added with its line's
// voice asked for, then the history's answer and the message shown.
// mock: MOCK_EDITOR=closed MOCK_ADD_NOTE=444 MOCK_RUN_FILES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "ankiEnabled": true, "ankiRenderTemplatesLocally": true, "checkForDuplicates": false, "duplicateBehavior": "new", "sentenceAudioEnabled": true, "sentenceAudioHistory": 0, "sentenceAudioBacklog": false, "sentenceAudioField": "SentenceAudio", "screenshotHistory": 0, "gamePause": false, "hotkeys": [{"action": "addNoteSentenceAudio", "argument": "0", "key": "KeyJ", "modifiers": ["alt"], "buttons": ["Button X"], "enabled": true}]}
// timeout: 60

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const button = await until('the add button', () => {
		const found = popupDocument()?.querySelector('.entry .action-button[data-action=save-note]');
		return found && !found.disabled && found;
	});
	equal(button.title, 'Add Mock note', 'the add button\'s title');
	const added = async () => (await mockLog()).filter((l) => /^anki \d+ addNote /.test(l)).length;
	const notRecorded = 'Game audio isn’t being recorded. Turn on “Record game audio for the last” in Settings → Anki Audio.';
	const perNote = ['[sentence audio] card 444 added, line 0: its line\'s voice asked for', `[sentence audio] history: ${notRecorded}`, `[sentence audio] message: ${notRecorded}`];
	const sentenceAudio = async () => (await runFile('app.log')).split('\n').filter((l) => l.startsWith('[sentence audio]'));

	await gamepadPress(['Button X'], { after: 0 });
	await until('a note added', async () => (await added()) >= 1, 5000).catch(() => {});
	await wait(2500);
	equal(await added(), 1, 'Button X: notes added');
	equal(await sentenceAudio(), perNote, 'Button X: Anki Audio\'s lines');

	window.__macpopupHotkey(0);
	await until('a second note added', async () => (await added()) >= 2, 5000).catch(() => {});
	await wait(2500);
	equal(await added(), 2, 'the keyboard shortcut: notes added');
	equal((await sentenceAudio()).slice(perNote.length), perNote, 'the keyboard shortcut: Anki Audio\'s new lines');
});
