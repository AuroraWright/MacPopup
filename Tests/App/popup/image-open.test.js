// Clicking a dictionary image in the popup opens it in its default app (Yomitan opens it in a new tab), from a copy named
// macpopup-media-<uuid>-red.png in the app's temporary folder: the 32×32 red image of MOCK_IMAGES. It opens Preview (or
// whatever opens PNGs) on the desktop: whoever runs it closes that window by hand afterwards (never scripted: quitting
// or closing windows in Preview would close the user's own pictures too).
// interactive
// mock: MOCK_IMAGES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true}
// driver: end=$((SECONDS + 50)); until grep -q 'TEST clicked' "$RUN/app.log" || (( SECONDS > end )); do sleep 0.2; done; sleep 3; f=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'macpopup-media-*-red.png' -newer "$RUN/script.js" | head -1); if [[ -n "$f" ]]; then echo "TEST ok the image is saved as $f"; size=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2}'); [[ "$size" == "32 32 " ]] && echo "TEST ok the saved image is 32×32" || echo "TEST FAIL the saved image's size: $size"; else echo "TEST FAIL no new macpopup-media-*-red.png in ${TMPDIR:-/tmp}"; fi; exit 0

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	await native('debugMouse', center(rangeOf(line, '晴').getBoundingClientRect()));
	const link = await until('the first image', () => popupDocument()?.querySelector('.entry .gloss-image-link'));
	equal(link.dataset.path, 'mock/red.png', 'the image clicked');
	log('clicked');
	link.click();
	await wait(5000);
});
