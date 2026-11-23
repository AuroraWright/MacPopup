// The OCR engine crash guard (OCRController.guardLoading): when the "engine was loading" marker is still saved as OCR
// starts, the engine crashed MacPopup while loading. Crashed on the GPU, it then loads on the CPU, saying so in the
// OCR toast ("… now runs on the CPU, which is slower."; the driver checks ocrEnginesOnCPU lists it); crashed on the
// CPU too, OCR switches to Live Text ("… so OCR now uses Live Text.", ocrEngine liveText). The driver writes the marker
// when asked ("TEST marker …"), as OCR is off; turning OCR Mode on then starts the engine (meikiocr, bundled).
// mock: MOCK_RUN_FILES=1
// settings: {"ocrMode": false, "ocrEngine": "meikiocr", "ocrCloudEngine": "none", "floatingWindowOCR": false}
// env: MACPOPUP_DEBUG_OCR=1
// driver: zsh "$REPO/Tests/App/ocr/ocr-crash-guard.driver.zsh"
// timeout: 120

test('overlay', async () => {
	const settings = async () => JSON.parse(await native('getSettings'));
	const setSettings = async (partial) => native('setSettings', { json: JSON.stringify({ ...(await settings()), ...partial }) });
	// The toasts shown from now on (the OCR overlay's or the text box's).
	const toasts = [];
	const watch = setInterval(() => {
		for (const toast of document.querySelectorAll('#ocr-toast, #toast')) {
			const text = toast.hidden ? '' : toast.textContent.trim();
			if (text && toasts.at(-1) !== text) toasts.push(text);
		}
	}, 50);
	const ready = async () => (await runFile('app.log')).split('\n').filter((l) => /meikiocr ready in/.test(l)).length;

	await wait(2000);
	log('marker gpu');
	await until('the driver writing the marker', async () => (await runFile('driver.log')).includes('marker gpu written'));
	await wait(1000);
	await setSettings({ ocrMode: true });
	await until('a toast', () => toasts.length > 0, 15000);
	equal(toasts, ['meikiocr crashed MacPopup while loading, so it now runs on the CPU, which is slower.'], 'crashed on the GPU: the toasts');
	await until('meikiocr loaded', async () => (await ready()) >= 1, 60000);
	equal((await settings()).ocrEngine, 'meikiocr', 'crashed on the GPU: the engine');

	await setSettings({ ocrMode: false });
	// The first toast gone (it shows for 4 s).
	await until('no toast shown', () => [...document.querySelectorAll('#ocr-toast, #toast')].every((t) => t.hidden), 10000);
	await wait(200);
	toasts.length = 0;
	log('marker cpu');
	await until('the driver writing the marker', async () => (await runFile('driver.log')).includes('marker cpu written'));
	await wait(1000);
	await setSettings({ ocrMode: true });
	await until('a toast', () => toasts.length > 0, 15000);
	await wait(1000);
	equal(toasts, ['meikiocr crashed MacPopup while loading, so OCR now uses Live Text.'], 'crashed on the CPU too: the toasts');
	equal((await settings()).ocrEngine, 'liveText', 'crashed on the CPU too: the engine');
	clearInterval(watch);
	await setSettings({ ocrMode: false });
	await wait(500);
});
