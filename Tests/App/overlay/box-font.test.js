// The Floating Window's Font (boxFontFamily, a PostScript name from the Fonts panel: Hiragino Mincho ProN W3): the
// text box's lines take it (WebKit takes PostScript names in font-family, so the text is drawn in it, not in the
// theme's font), the font is there, and the page loads nothing from the web (no web fonts).
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "boxFontFamily": "HiraMinProN-W3"}
// timeout: 60

test('overlay', async () => {
	const line = await lineWith('明日も晴れるといいね');
	await wait(500);
	const lines = document.querySelector('#lines');
	equal(getComputedStyle(lines).fontFamily, 'HiraMinProN-W3', 'the text box\'s font-family');
	equal(getComputedStyle(line).fontFamily, 'HiraMinProN-W3', 'the line\'s font-family');
	await document.fonts.ready;
	// Drawn in it: the same text is as wide in the line's font as in Hiragino Mincho ProN, and not as in the theme's.
	const width = (font) => {
		const context = document.createElement('canvas').getContext('2d');
		context.font = font;
		return Math.round(context.measureText('Mincho, 明日も晴れる').width * 10) / 10;
	};
	const size = getComputedStyle(line).fontSize;
	const inLineFont = width(`${size} ${getComputedStyle(line).fontFamily}`);
	// (The font is there: a missing one would measure as the fallback, monospace here.)
	expect(width(`${size} "Hiragino Mincho ProN", monospace`) !== width(`${size} monospace`), 'Hiragino Mincho ProN is available');
	equal(inLineFont, width(`${size} "Hiragino Mincho ProN"`), 'text width in the line\'s font, as in Hiragino Mincho ProN');
	expect(inLineFont !== width(`${size} "Hiragino Sans"`), `text width in the line's font (${inLineFont}) isn't Hiragino Sans' (${width(`${size} "Hiragino Sans"`)})`);
	const remote = performance.getEntriesByType('resource').map((e) => e.name).filter((url) => /^https?:/.test(url));
	equal(remote, [], 'resources loaded from the web');
});
