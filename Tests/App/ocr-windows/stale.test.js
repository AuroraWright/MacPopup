// Debug boxes after a giant misreading (fake readings, made up after CHAOS;HEAD NOAH's of 2026-11-14; no test window):
// two vertical "lines" of characters in boxes far wider than tall, then the dialogue line. With Debug on, the glyphs are
// drawn as a text-shadow that can reach past their line's box, and WebKit didn't repaint that when the line was removed,
// so pieces stayed on screen: each debug line is clipped to its box (overflow: clip), and after the dialogue line only
// it is left. (The pixels themselves aren't checked: that needs a capture of the overlay.)
// settings: {"ocrMode": true, "ocrCloudEngine": "none", "ocrShowBoxes": true, "displayIndex": 0, "screenshotHistory": 0}
// timeout: 60

test('overlay', async () => {
	const W = { x: 0, y: 44, width: 2056, height: 1285 };
	// A vertical line of characters in boxes 760 wide and 120-200 tall, at x.
	const giantLine = (text, x) => ({
		text, vertical: true, x, y: 135, width: 760, height: 1100, area: 0,
		chars: [...text].map((c, i) => [c, x + 20, 140 + i * 130, 760, 120 + (i % 3) * 40]),
	});
	const giant = { type: 'result', width: W.width, height: W.height, lines: [giantLine('大きな目だれの目', 900), giantLine('しはよく草た', 245)] };
	const text = '背中を預けていたイスの背もたれが、しわがれた声みたいな音をたてて軋んだ。';
	const line = {
		type: 'result', width: W.width, height: W.height,
		lines: [{ text, vertical: false, x: 217, y: 966, width: 1534, height: 44, area: 0,
			chars: [...text].map((c, i) => [c, 212 + i * 41.5, 967, 41.5, 44]) }],
	};
	const lines = () => [...document.querySelectorAll('#ocr-text .ocr-line')];

	await wait(2000);
	window.__macpopupOcr({ type: 'window', visible: true, ...W });
	window.__macpopupOcr(giant);
	await wait(500);
	equal(document.querySelector('#ocr-layer')?.classList.contains('show-boxes'), true, 'Debug on: the layer shows boxes');
	equal(lines().map((l) => l.textContent), ['大きな目だれの目', 'しはよく草た'], 'the giant reading\'s lines');
	equal(lines().map((l) => getComputedStyle(l).overflow), ['clip', 'clip'], 'the giant lines clipped to their boxes');
	await wait(1000);
	window.__macpopupOcr(line);
	await wait(500);
	equal(lines().map((l) => l.textContent), [text], 'after the dialogue line: the lines');
	equal(ocrText(), text, 'after the dialogue line: the text');
	equal(lines().map((l) => getComputedStyle(l).overflow), ['clip'], 'the dialogue line clipped to its box');
	window.__macpopupOcr({ type: 'window', visible: false });
});
