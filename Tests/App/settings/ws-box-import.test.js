// Settings → WebSockets' URL box with real keys (ws-box-driver.py import): The list changed while Settings is open,
// after an edit that left the text as it was (Return, Backspace, ⌃⇥): the page then saves 5 URLs, as an import would,
// and the box shows them, growing to 5 lines (it stayed at 2 without LinesEditor's onChange).
// Types into the test instance's Settings window and clicks into its URL box (only while it's in front; the pointer is
// put back afterwards).
// interactive
// mock: MOCK_RUN_FILES=1
// settings: {"websocketUrls": ["ws://127.0.0.1:59900"], "showConnectionErrors": false, "continuousReconnect": false}
// driver: python3 -I "$REPO/Tests/App/settings/ws-box-driver.py" import
// timeout: 90

if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));

test('overlay', async () => {
	await driverSaid('edited', 80000);
	const settings = JSON.parse((await native('getSettings')) || '{}');
	settings.websocketUrls = [1, 2, 3, 4, 5].map((n) => `ws://127.0.0.1:5991${n}`);
	await native('setSettings', { json: JSON.stringify(settings) });
	log('saved 5 URLs');
	await wait(1000);
	equal(JSON.parse(await native('getSettings')).websocketUrls.length, 5, 'URLs saved by the page');
	await wait(4000);
});
