// Collapsed definitions in a 150-entry popup (OwOtan's ElementOverflowController plus MacPopup's checkAdded), looked up
// 3 times: no frame shows an entry whose definitions haven't been checked yet (their expand buttons missing); once
// settled, the first entries' long definitions are all collapsible and checked, while the last entry, far below the
// view, isn't checked yet; a wider popup checks them again (none left unchecked); scrolling to the end checks the last
// entries (all those in view); moving off the text hides the popup (autoHideResults) and removes its entries.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "autoHideResults": true, "definitionsCollapsible": "collapsed", "popupWidth": 300, "popupFontSize": 14, "popupHeight": 900}
// timeout: 90

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	const word = center(rangeOf(line, '晴').getBoundingClientRect());
	const doc = () => popupDocument();
	const count = () => doc()?.querySelectorAll('#dictionary-entries > .entry').length ?? 0;
	const visible = () => [...document.querySelectorAll('iframe')].some((frame) => getComputedStyle(frame).visibility === 'visible');
	// [collapsible definitions, definitions, definitions not checked yet]
	const checked = (entry) => (entry ? [entry.querySelectorAll('.collapsible').length, entry.querySelectorAll('.definition-item-inner').length,
		entry.querySelectorAll('.collapse-test').length] : null);
	for (const n of [1, 2, 3]) {
		await wait(500);
		// Each frame, before it's drawn: the entries in view whose definitions haven't been checked.
		const frames = { count: 0, gaps: 0, worst: 0, stop: false };
		const probe = () => {
			if (frames.stop) return;
			requestAnimationFrame(probe);
			const d = doc();
			if (!d?.querySelector('#content-scroll')) return;
			const view = d.querySelector('#content-scroll').getBoundingClientRect();
			const inView = [...d.querySelectorAll('#dictionary-entries > .entry')].filter((e) => {
				const r = e.getBoundingClientRect();
				return r.bottom > view.top && r.top < view.bottom;
			});
			const unchecked = inView.filter((e) => e.querySelector('.collapse-test')).length;
			if (getComputedStyle(d.defaultView.frameElement).visibility === 'visible' && inView.length > 0) {
				frames.count++;
				if (unchecked > 0) frames.gaps++;
				frames.worst = Math.max(frames.worst, unchecked);
			}
		};
		// (The overlay's frames are the popup's: the popup's page is replaced as it loads in the first lookup.)
		requestAnimationFrame(probe);
		await native('debugMouse', word);
		await until(`lookup ${n}'s 150 entries`, () => count() >= 150, 20000);
		await wait(800);
		frames.stop = true;
		expect(frames.gaps === 0 && frames.count > 0,
			`lookup ${n}: frames with unchecked entries in view: ${frames.gaps} of ${frames.count} (at most ${frames.worst} entries)`);
		const entries = [...doc().querySelectorAll('#dictionary-entries > .entry')];
		equal([0, 1, 2].map((i) => checked(entries[i])), [[6, 6, 0], [6, 6, 0], [6, 6, 0]], `lookup ${n}: the first entries' definitions once settled`);
		const last = checked(entries[149]);
		expect(last[2] > 0, `lookup ${n}: the last entry isn't checked before it's near the view: ${last}`);

		// A wider popup: the definitions that were checked are checked again.
		const frameElement = document.querySelector('iframe.yomitan-popup');
		frameElement.style.width = `${frameElement.getBoundingClientRect().width + 40}px`;
		await wait(600);
		equal([0, 1, 2].map((i) => checked(entries[i])[2]), [0, 0, 0], `lookup ${n}: definitions not checked in the first entries after widening`);
		frameElement.style.width = `${frameElement.getBoundingClientRect().width - 40}px`;
		await wait(600);
		const scroll = doc().querySelector('#content-scroll');
		scroll.scrollTop = scroll.scrollHeight;
		await wait(400);
		const view = scroll.getBoundingClientRect();
		const inView = entries.map((e, i) => [e.getBoundingClientRect(), i]).filter(([r]) => r.bottom > view.top && r.top < view.bottom).map(([, i]) => i);
		expect(inView.includes(149) && inView.every((i) => checked(entries[i])[2] === 0),
			`lookup ${n}: after scrolling to the end, entries in view ${inView.join(', ')}: definitions not checked ${inView.map((i) => checked(entries[i])[2])}`);

		// Away from the text, so the popup hides and the next hover looks up again.
		await native('debugMouse', { x: 5, y: 5 });
		await until(`the popup hidden after lookup ${n}`, () => !visible(), 3000).catch(() => {});
		expect(!visible() && count() === 0, `lookup ${n}: hidden ${!visible()}, entries left ${count()}`);
	}
});
