// The Floating Window's Font effects (boxFontEffects, from the Fonts panel) and Line spacing in pixels (linePadding):
// the text box takes the effects' color, shadow and strikethrough (on all lines), each line the underline (its own
// style and color, as WebKit's text-decoration shorthand takes only the line) and the padding above and below, and the
// box's background the background color. (The old script's screenshot of the box isn't ported: styles only.)
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "fontSize": 30, "linePadding": 7, "boxFontEffects": {"color": "#ff8800ff", "backgroundColor": "#10203080", "underline": "double", "underlineColor": "#00ff00ff", "strikethrough": "single", "strikethroughColor": "#0000ffff", "shadow": {"x": 2, "y": 3, "blur": 4, "color": "#000000ff"}}}
// timeout: 60

test('overlay', async () => {
	const p = await lineWith('明日も晴れるといいね');
	await wait(500);
	const lines = document.querySelector('#lines');
	const style = (element) => getComputedStyle(element);
	equal(style(lines).fontSize, '30px', 'the text box\'s font size');
	equal(style(lines).color, 'rgb(255, 136, 0)', 'the text color');
	equal(style(lines).textShadow, 'rgb(0, 0, 0) 2px 3px 4px', 'the shadow');
	equal([style(lines).textDecorationLine, style(lines).textDecorationStyle, style(lines).textDecorationColor],
		['line-through', 'solid', 'rgb(0, 0, 255)'], 'the strikethrough (line, style, color)');
	equal([style(p).textDecorationLine, style(p).textDecorationStyle, style(p).textDecorationColor],
		['underline', 'double', 'rgb(0, 255, 0)'], 'the line\'s underline (line, style, color)');
	equal([style(p).paddingTop, style(p).paddingBottom], ['7px', '7px'], 'the line\'s padding above and below');
	equal(style(document.querySelector('#box-background')).backgroundColor, 'rgba(16, 32, 48, 0.5)', 'the box\'s background color');
});
