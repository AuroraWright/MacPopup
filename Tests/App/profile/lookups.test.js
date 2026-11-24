// The app's memory and CPU over a series of lookups (profile-driver.py lookups): each of a clipboard line's first 8
// characters looked up in turn, 6 rounds (48 popups of the mock's 150 entries, each replacing the last), then 10 s
// idle. All 48 popups shown; peak footprints at most 50 MB for MacPopup, 600 MB for its WebContent and 750 MB for all
// its processes; at most 490 ms of CPU per lookup, all processes (about 1.5x the most measured; see the driver).
// mock: MOCK_RUN_FILES=1
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true}
// driver: python3 -I "$REPO/Tests/App/profile/profile-driver.py" lookups
// timeout: 150

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	const node = document.createTreeWalker(line, NodeFilter.SHOW_TEXT).nextNode();
	const points = [...Array(Math.min(8, node.data.length)).keys()].map((i) => {
		const range = document.createRange();
		range.setStart(node, i);
		range.setEnd(node, i + 1);
		return center(range.getBoundingClientRect());
	});
	// The driver's sample before the lookups (CPU time per lookup is from it to one at "lookups end").
	log('lookups ready');
	await driverSaid('sampling', 30000);
	let shown = 0;
	const start = Date.now();
	for (let round = 0; round < 6; round++) {
		for (const p of points) {
			// The last popup's entries marked first: a new popup's are new (the popup stays open between lookups).
			popupDocument()?.querySelectorAll('#dictionary-entries > .entry').forEach((entry) => { entry.dataset.seen = '1'; });
			await native('debugMouse', p);
			const fresh = () => popupDocument()?.querySelector('#dictionary-entries > .entry:not([data-seen])');
			for (let i = 0; i < 40 && !fresh(); i++) await wait(50);
			if (fresh()) shown++;
			await wait(400);
			await native('debugMouse', { x: 5, y: 5 });
			await wait(300);
		}
		log(`round ${round + 1} ${Date.now() - start} ms`);
	}
	log('lookups end');
	log(`popups ${shown}/48`);
	equal(shown, 48, 'popups shown');
	await wait(10000);
});
