// Settings' labels and hints stay put when a control changes width (sections-driver.py steady, after
// evals/settings-shot/steady-pairs.sh): Anki Screenshot's resolution (1x, full), OCR Overlay's controller
// start (bottom, top), General's language and captured window (ja and a window "A", en and a long title), Yomitan
// Popup's themes, scale and size (narrow and wide values). The page sets each value while Settings is open, as the
// driver asks; the left column's texts keep their frames and pixels (screenshots in the run folder).
// mock: MOCK_RUN_FILES=1
// driver: python3 -I "$REPO/Tests/App/settings/sections-driver.py" steady
// timeout: 150

test('overlay', async () => {
	await wait(2000);
	native('openSettings');
	for (let n = 1; ; n++) {
		const said = await until(`the driver's step ${n}`, async () => (await runFile('driver.log')).split('\n')
			.find((line) => line.startsWith(`apply ${n} `) || line === 'apply end'), 60000);
		if (said === 'apply end') break;
		const values = JSON.parse(said.slice(`apply ${n} `.length));
		await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), ...values }) });
		const saved = JSON.parse(await native('getSettings'));
		equal(Object.fromEntries(Object.keys(values).map((key) => [key, saved[key]])), values, `step ${n}'s settings saved`);
		log(`applied ${n}`);
	}
});
