// Autoplay with a 150-entry lookup: the first entry's audio is asked for and played as soon as that entry is shown,
// without waiting for the other entries (it comes before the last one); a second lookup of the same word plays it
// again from the cache, without asking the source again. Moving the pointer off the text hides the popup each time
// (autoHideResults).
// Timing: the order of events, and generous bounds only.
// clipboard: 明日も晴れるといいね
// settings: {"clipboardMonitor": true, "autoHideResults": true, "audioEnabled": true, "audioAutoPlay": true, "audioVolume": 0, "audioFallbackSound": "none", "audioDefaultSources": false, "audioSources": [{"type": "custom", "url": "http://127.0.0.1:59879/autoplay/{term}"}]}

test('overlay', async () => {
	const line = await lineWith('明日も晴れる');
	const word = center(rangeOf(line, '晴').getBoundingClientRect());
	const frames = () => [...document.querySelectorAll('iframe')];
	const count = () => Math.max(0, ...frames().map((frame) => frame.contentDocument?.querySelectorAll('#dictionary-entries > .entry').length ?? 0));
	const visible = () => frames().some((frame) => frame.getBoundingClientRect().width > 0 && getComputedStyle(frame).visibility !== 'hidden'
		&& getComputedStyle(frame).display !== 'none' && getComputedStyle(frame).opacity !== '0');
	// play() calls, with the lookup they came in.
	const plays = [];
	let lookup = 0;
	const audioRequests = async () => (await mockLog()).filter((l) => l.startsWith('audio ')).map((l) => ({ time: Number(l.split(' ')[1]), path: l.split(' ')[2] }));
	for (const n of [1, 2]) {
		await wait(500);
		lookup = n;
		const hover = Date.now();
		await native('debugMouse', word);
		let first = null, all = null;
		for (let i = 0; i < 2000 && all === null; i++) {
			// Each popup page's play() is counted, from as soon as it exists.
			for (const frame of frames()) {
				const proto = frame.contentWindow?.HTMLMediaElement?.prototype;
				if (proto && !proto.__counted) {
					proto.__counted = true;
					const play = proto.play;
					proto.play = function (...args) {
						plays.push({ n: lookup, time: Date.now() });
						return play.apply(this, args);
					};
				}
			}
			const c = count();
			if (c > 0 && first === null) first = Date.now();
			if (c >= 150) all = Date.now();
			await wait(5);
		}
		await wait(1500);
		expect(first !== null && all !== null, `lookup ${n}: the first entry after ${first - hover} ms, all 150 after ${all - hover} ms`);
		const played = plays.filter((p) => p.n === n);
		equal(played.length, 1, `lookup ${n}: audio played`);
		if (n === 1) {
			const requests = await audioRequests();
			equal(requests.length, 1, 'audio requests after the first lookup');
			const asked = requests[0]?.time;
			expect(asked >= first - 50 && asked < all, `the audio is asked for after the first entry and before the last: ${asked - hover} ms (first ${first - hover}, all ${all - hover})`);
			expect(played[0]?.time - hover < 5000, `the first lookup's audio plays within 5 s: ${played[0]?.time - hover} ms`);
		} else {
			equal((await audioRequests()).length, 1, 'audio requests after the second lookup (cached)');
			expect(played[0]?.time < all, `the second lookup's audio plays before the last entry is shown: ${played[0]?.time - hover} ms (all ${all - hover})`);
		}
		// Away from the text, so the popup hides and the next hover looks up again.
		await native('debugMouse', { x: 5, y: 5 });
		await until(`the popup hidden after lookup ${n}`, () => !visible(), 3000).catch(() => {});
		expect(!visible(), `lookup ${n}: the popup hides when the pointer leaves`);
	}
});
