// The Yomitan profile through the API (MOCK_PROFILE=1: a Yomitan with displayOptions, dictionaryInfo and
// dictionaryMedia), with "Use Yomitan's display settings" on: the popup shows the profile's display options (theme,
// font, scale, layout, custom popup and outer CSS), its result grouping, the Mock dictionary's styles, collapse mode
// and details (its tag's notification), and the images from dictionaryMedia (red: ankiFields' are green). Saving
// settings (the clipboard button, twice) saves only MacPopup's own settings, none of the profile's.
// mock: MOCK_IMAGES=1 MOCK_PROFILE=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "definitionsCollapsible": "not-collapsible"}

test('overlay', async () => {
	const expected = {
		data: { resultOutputMode: 'split', glossaryLayoutMode: 'compact', compactTags: 'true', termDisplayMode: 'term-and-reading',
			enableSearchTags: 'true', popupCurrentIndicatorMode: 'asterisk', popupActionBarVisibility: 'always', popupActionBarLocation: 'bottom',
			theme: 'dark', outerTheme: 'dark' },
		font: ['Georgia', '21px', '1.8', '1.25em'],
		customCss: true,
		dictionary: true,
		mockLines: { 'yomitan-400 displayOptions': false, 'yomitan-media': true },
	};

	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const iframe = () => document.querySelector('iframe.yomitan-popup');
	const canvases = await until('the two images', () => {
		const found = [...(popupDocument()?.querySelectorAll('.entry canvas.gloss-image') ?? [])];
		return found.length >= 2 && found;
	});
	await wait(1500);
	const d = popupDocument();
	const root = d.documentElement;
	const style = (element) => element.ownerDocument.defaultView.getComputedStyle(element);
	const data = Object.fromEntries(Object.keys(expected.data).map((key) => [key, root.dataset[key]]));
	equal(data, expected.data, 'the popup\'s display attributes');
	equal([root.style.fontFamily, root.style.fontSize, root.style.lineHeight, d.body.style.fontSize], expected.font, 'font, size, line height, scale');
	const entry = d.querySelector('.entry');
	equal([style(entry).outlineColor === 'rgb(0, 0, 255)', style(iframe()).outlineColor === 'rgb(255, 0, 255)'], [expected.customCss, expected.customCss],
		`the custom popup CSS (entry outline ${style(entry).outline}) and outer CSS (frame outline ${style(iframe()).outline})`);
	const gloss = d.querySelector('.entry .gloss-content');
	equal(style(gloss).color === 'rgb(0, 160, 0)', expected.dictionary, `the Mock dictionary's styles (gloss color ${style(gloss).color})`);
	const inner = d.querySelector('.entry .definition-item-inner');
	const attributes = [...inner.attributes].map(({ name, value }) => `${name}=${value}`).join(' ');
	equal(inner.classList.contains('collapsible') && inner.classList.contains('collapsed'), expected.dictionary,
		`the Mock dictionary's force-collapsed definitions (${attributes})`);
	const tag = d.querySelector('.entry .tag[data-category=dictionary]');
	tag.querySelector('.tag-label').click();
	await wait(500);
	const details = [...d.querySelectorAll('.footer-notification-body')].map((body) => body.textContent.replace(/\s+/g, ' ').trim()).filter(Boolean).join(' | ');
	equal(details.includes('A mock dictionary') && details.includes('Mock Author'), expected.dictionary,
		`the dictionary tag's details: ${details.slice(0, 200)}`);
	const pixels = canvases.map((canvas) => {
		const link = canvas.closest('.gloss-image-link');
		return `${link.dataset.path} ${link.dataset.appearance} ${[...canvas.getContext('2d').getImageData(canvas.width >> 1, canvas.height >> 1, 1, 1).data]}`;
	});
	equal(pixels.slice(0, 1), ['mock/red.png auto 255,0,0,255'], `the images (${pixels.join(' | ')})`);
	const mock = await mockLog();
	equal(Object.fromEntries(Object.keys(expected.mockLines).map((key) => [key, mock.some((l) => l.startsWith(key))])), expected.mockLines,
		'Yomitan API answers in the mock log');

	// Saving settings saves the stored ones only.
	document.querySelector('#clipboard-button').click();
	await wait(500);
	document.querySelector('#clipboard-button').click();
	await wait(1000);
	const stored = JSON.parse(await native('getSettings'));
	equal({ clipboardMonitor: stored.clipboardMonitor, popupTheme: stored.popupTheme, popupFontSize: stored.popupFontSize,
		glossaryLayoutMode: stored.glossaryLayoutMode, customPopupCss: stored.customPopupCss, dictionaryStyles: stored.dictionaryStyles,
		hasDictionaryInfo: 'yomitanDictionaryInfo' in stored, resultOutputMode: stored.yomitanAnkiTemplates?.resultOutputMode ?? null },
	{ clipboardMonitor: true, popupTheme: 'site', popupFontSize: 14, glossaryLayoutMode: 'default', customPopupCss: '', dictionaryStyles: [],
		hasDictionaryInfo: false, resultOutputMode: null },
	'the settings saved');
});
