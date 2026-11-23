// The Floating Window's "Hide lines not matching the language" (filterNonCJKLines) with Japanese: copied lines in
// Japanese, English, Russian, "……" (no letters) and 『MentalLock』 (Japanese brackets): the box shows all but the English
// and Russian ones. The driver copies the lines after the first (明日も晴れるといいね), 1.5 s apart.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "filterNonCJKLines": true, "language": "ja", "preventLastDuplicate": 0, "maxLines": 0, "ocrMode": false, "floatingWindowOCR": false}
// driver: until grep -q 'TEST ok the first line' "$RUN/app.log" 2>/dev/null; do sleep 0.1; done; for t in 'Hello there' 'こんにちは' 'привет' '……' '『MentalLock』'; do "$REPO/build/test/tools/pb" "$SUITE" "$t"; sleep 1.5; done
// timeout: 60

test('overlay', async () => {
	const lines = () => [...document.querySelectorAll('#lines p[data-line-id]')].map((p) => p.textContent.trim());
	await lineWith('明日も晴れるといいね');
	equal(lines(), ['明日も晴れるといいね'], 'the first line');
	// The last line copied, or (if it's left out) the time the driver takes.
	await lineWith('『MentalLock』', 12000).catch(() => {});
	await wait(1500);
	equal(lines(), ['明日も晴れるといいね', 'こんにちは', '……', '『MentalLock』'], 'the box\'s lines');
});
