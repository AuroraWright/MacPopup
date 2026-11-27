// The overlay connects to the first 5 WebSocket URLs (maxWebsocketUrls) whatever an import or an older version saved
// (which launch also cuts down to them, see SettingsSchema.clampStored): with 7 saved, and empty ones among them that
// don't count, the Floating Window has 5 WebSocket icons, all connected, and only the first 5 servers see a connection.
// mock: MOCK_WEBSOCKET_PORTS=59890,59891,59892,59893,59894,59895,59896
// settings: {"websocketUrls": ["ws://127.0.0.1:59890", "", "ws://127.0.0.1:59891", "ws://127.0.0.1:59892", "  ", "ws://127.0.0.1:59893", "ws://127.0.0.1:59894", "ws://127.0.0.1:59895", "ws://127.0.0.1:59896"]}

test('overlay', async () => {
	const icons = () => [...document.querySelectorAll('#socket-icons > *')];
	const connected = () => icons().filter((icon) => icon.classList.contains('text-green-700'));
	await until('5 connected WebSockets', () => connected().length >= 5, 10000).catch(() => {});
	await wait(2000);
	equal(icons().map((icon) => icon.title), [59890, 59891, 59892, 59893, 59894].map((port) => `WebSocket 127.0.0.1:${port}`),
		'the WebSocket icons');
	equal(connected().length, 5, 'connected icons');
	const ports = (await mockLog()).filter((line) => line.startsWith('websocket-port ')).map((line) => Number(line.split(' ')[1]));
	equal([...new Set(ports)].sort(), [59890, 59891, 59892, 59893, 59894], 'the servers connected to');
	equal(ports.length, 5, 'connections made');
});
