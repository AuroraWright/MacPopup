// The WebSocket server MacPopup connects to (add ws://localhost:<port> in its Settings → WebSockets), shared by every
// player window: each window's main.js sends its subtitle lines here.
//
// Messages to MacPopup: {"sentence": text, "player": {"line", "start", "end", "video", "audio"}} for each line
// (texthooker's format plus the player's part), where video and audio are {"file", "stream"} or null.
//
// IINA's server listens on every network interface and can't close a connection, so connections from other devices
// are ignored: they get no lines.
const { ws, global, preferences, console } = iina;

// The connections from this Mac.
const connections = new Set();
// The last line, sent to MacPopup when it connects (OCR Mode matches the window's text with it).
let lastLine = null;

function send(connection, message) {
	ws.sendText(connection, JSON.stringify(message)).catch((error) => console.log(`Sending failed: ${JSON.stringify(error)}`));
}

// The peer's address, as "127.0.0.1:port" or "::1.port".
const isLocal = (address) => /^(127\.|::1\.|::ffff:127\.)/.test(address ?? '');

ws.onNewConnection((connection, info) => {
	if (!isLocal(info?.path)) {
		console.log(`Ignoring a connection from ${info?.path}`);
		return;
	}
	connections.add(connection);
	if (lastLine) send(connection, lastLine);
});

ws.onConnectionStateUpdate((connection, state) => {
	if (state === 'failed' || state === 'cancelled') connections.delete(connection);
});

global.onMessage('line', (line, player) => {
	lastLine = { sentence: line.text, player: { ...line.player, line: `${player}#${line.number}` } };
	for (const connection of connections) send(connection, lastLine);
});

ws.onStateUpdate((state, error) => {
	if (state === 'failed') console.log(`The WebSocket server failed: ${error?.description ?? ''}`);
});
ws.createServer({ port: Number(preferences.get('port')) || 6680 });
ws.startServer();
