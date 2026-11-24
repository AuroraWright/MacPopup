// The overlay's WebSocket connections follow the saved URLs while it runs (after evals/settings-shot/
// ws-count.js, which counted its icons; websocket-limit.test.js checks them at launch): with 2 saved, 2 icons; then 7
// saved (as an import or Settings would, with a blank one that doesn't count), the first 5, all connected; then 1 saved,
// 1 icon. Each server sees a connection only while its URL is among the first 5.
// mock: MOCK_WEBSOCKET_PORTS=59890,59891,59892,59893,59894,59895,59896
// settings: {"websocketUrls": ["ws://127.0.0.1:59890", "ws://127.0.0.1:59891"], "showConnectionErrors": false}

test('overlay', async () => {
	const icons = () => [...document.querySelectorAll('#socket-icons > *')];
	const connected = () => icons().filter((icon) => icon.classList.contains('text-green-700'));
	const titles = (ports) => ports.map((port) => `WebSocket 127.0.0.1:${port}`);
	const save = async (urls) => native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), websocketUrls: urls }) });
	const expectIcons = async (ports, what) => {
		await until(`${ports.length} connected WebSockets`, () => connected().length === ports.length && icons().length === ports.length, 10000).catch(() => {});
		await wait(1000);
		equal(icons().map((icon) => icon.title), titles(ports), `the WebSocket icons ${what}`);
		equal(connected().length, ports.length, `connected icons ${what}`);
	};
	const servers = async () => (await mockLog()).filter((line) => line.startsWith('websocket-port ')).map((line) => Number(line.split(' ')[1]));
	// The ports with a connection open (connections less ends, in mock.log).
	const open = async () => {
		const count = {};
		for (const line of await mockLog()) {
			const [kind, port] = line.split(' ');
			if (kind === 'websocket-port') count[port] = (count[port] ?? 0) + 1;
			if (kind === 'websocket-port-closed') count[port] -= 1;
		}
		return Object.keys(count).filter((port) => count[port] > 0).map(Number).sort();
	};

	await expectIcons([59890, 59891], 'with 2 saved');
	await save(['ws://127.0.0.1:59890', 'ws://127.0.0.1:59891', ' ', 'ws://127.0.0.1:59892', 'ws://127.0.0.1:59893',
		'ws://127.0.0.1:59894', 'ws://127.0.0.1:59895', 'ws://127.0.0.1:59896']);
	await expectIcons([59890, 59891, 59892, 59893, 59894], 'with 7 saved');
	equal([...new Set(await servers())].sort(), [59890, 59891, 59892, 59893, 59894], 'the servers connected to');
	equal(await open(), [59890, 59891, 59892, 59893, 59894], 'the servers with a connection open, with 7 saved');
	await save(['ws://127.0.0.1:59893']);
	await expectIcons([59893], 'with 1 saved');
	await until('the other connections closed', async () => (await open()).length === 1, 5000).catch(() => {});
	equal(await open(), [59893], 'the servers with a connection open, with 1 saved');
});
