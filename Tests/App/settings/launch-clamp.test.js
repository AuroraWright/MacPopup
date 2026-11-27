// Settings saved outside Settings' limits (by an older version, or a backup edited by hand) are brought within them at
// launch (SettingsSchema.clampStored), before anything reads them: numbers into their range, WebSocket URLs to the first
// 5 with something on them, backlog keys to 5, termination characters to one character. Others are left as they are.
// settings: {"popupWidth": 123456789012, "popupFontSize": 0, "maxLines": 5000, "scanLength": 16, "popupTheme": "dark", "websocketUrls": ["ws://127.0.0.1:59990", "", "ws://127.0.0.1:59991", "  ", "ws://127.0.0.1:59992", "ws://127.0.0.1:59993", "ws://127.0.0.1:59994", "ws://127.0.0.1:59995"], "showConnectionErrors": false, "sentenceAudioOpenKeys": [{"key": "KeyA", "modifiers": []}, {"key": "KeyB", "modifiers": []}, {"key": "KeyC", "modifiers": []}, {"key": "KeyD", "modifiers": []}, {"key": "KeyE", "modifiers": []}, {"key": "KeyF", "modifiers": []}, {"key": "KeyG", "modifiers": []}], "sentenceTerminationCharacters": [{"enabled": true, "character1": "「long", "character2": "」long", "includeCharacterAtStart": false, "includeCharacterAtEnd": false}]}

test('overlay', async () => {
	const saved = JSON.parse(await native('getSettings'));
	equal(saved.popupWidth, 2000, 'popupWidth down to its maximum');
	equal(saved.popupFontSize, 8, 'popupFontSize up to its minimum');
	equal(saved.maxLines, 1000, 'maxLines down to its maximum');
	equal(saved.scanLength, 16, 'scanLength in range, kept');
	equal(saved.popupTheme, 'dark', 'other settings kept');
	equal(saved.websocketUrls, [0, 1, 2, 3, 4].map((n) => `ws://127.0.0.1:${59990 + n}`), 'websocketUrls: the first 5 with something on them');
	equal(saved.sentenceAudioOpenKeys.map((key) => key.key), ['KeyA', 'KeyB', 'KeyC', 'KeyD', 'KeyE'], 'sentenceAudioOpenKeys: the first 5');
	equal([saved.sentenceTerminationCharacters[0].character1, saved.sentenceTerminationCharacters[0].character2], ['「', '」'],
		'termination characters: one character');
});
