// Dictionary images in the popup: a colored image keeps its colors, and a monochrome one takes the popup's text color
// (drawn colored, as Yomitan's CSS filter doesn't work in WebKit).
// mock: MOCK_IMAGES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const canvases = await until('the two images', () => {
		const found = [...(popupDocument()?.querySelectorAll('.entry canvas.gloss-image') ?? [])];
		return found.length >= 2 && found;
	});
	await wait(1500);
	const style = (element) => element.ownerDocument.defaultView.getComputedStyle(element);
	const pixel = (canvas) => [...canvas.getContext('2d').getImageData(canvas.width >> 1, canvas.height >> 1, 1, 1).data];
	const [red, mono] = canvases;
	equal(red.closest('.gloss-image-link').dataset.appearance, 'auto', 'the first image\'s appearance');
	equal(pixel(red), [255, 0, 0, 255], 'the colored image\'s center');

	equal(mono.closest('.gloss-image-link').dataset.appearance, 'monochrome', 'the second image\'s appearance');
	equal(style(mono).filter, 'none', 'the monochrome image\'s filter');
	const probe = mono.ownerDocument.createElement('span');
	probe.style.color = 'var(--text-color)';
	mono.parentElement.append(probe);
	const text = style(probe).color.match(/\d+(\.\d+)?/g).slice(0, 3).map(Number);
	probe.remove();
	const [r, g, b, a] = pixel(mono);
	expect(a === 255 && [r, g, b].every((c, i) => Math.abs(c - text[i]) <= 2),
		`the monochrome image's center ${[r, g, b, a]} is the text color ${text}`);
});
