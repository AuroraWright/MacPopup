// The WebSocket server MacPopup connects to (add ws://localhost:<port> in its Settings → WebSockets), shared by every
// player window: each window's main.js sends its subtitle lines here.
//
// Messages to MacPopup: {"sentence": text, "player": {"line", "start", "end", "video", "audio"}} for each line
// (texthooker's format plus the player's part), where video and audio are where MacPopup reads them from (see
// main.js): {"file", "stream"}, {"url", "stream", "headers", "proxy"}, {"fragments": key}, {"cache": key} or null.
// Requests from MacPopup, which the player window with the key (its label as of its last line) answers:
// - {"fragments": {"id", "key", "type", "start", "end"}} for a "fragments" track: {"reply": {"id", "init", "parts":
//   [{"url", "start", "length"}], "headers", "proxy"}}, the DASH init segment and the fragments the time range is in.
// - {"dump": {"id", "key", "start", "end", "file"}} for a "cache" track: dumps the range into the file (in MacPopup's
//   temporary folder, which MacPopup deletes) and answers {"reply": {"id", "file"}}.
// Or {"reply": {"id", "error"}}.
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

// The player windows' labels (which global.postMessage can reach them by) by their keys (see main.js).
const players = new Map();

global.onMessage('line', (line, player) => {
	players.set(line.key, player);
	lastLine = { sentence: line.text, player: { ...line.player, line: `${player}#${line.number}` } };
	for (const connection of connections) send(connection, lastLine);
});

// The connections waiting for a reply, by request id.
const waiting = new Map();

ws.onMessage((connection, message) => {
	if (!connections.has(connection)) return;
	let kind = null;
	let request = null;
	try {
		const body = JSON.parse(message.text());
		kind = ['fragments', 'dump'].find((name) => body?.[name]);
		request = kind ? body[kind] : null;
	} catch (_) {
		return;
	}
	const valid =
		typeof request?.id === 'string' && /^[0-9A-F-]{36}$/i.test(request.id) && typeof request.key === 'string'
		&& typeof request.start === 'number' && typeof request.end === 'number'
		&& request.start >= 0 && request.end > request.start && request.end - request.start <= 600
		&& (kind === 'fragments'
			? request.type === 'video' || request.type === 'audio'
			// Only a file of this name in a temporary folder, whoever asks.
			: typeof request.file === 'string'
				&& new RegExp(`^/(private/)?var/folders/[^/]+/[^/]+/T/macpopup-dump-${request.id}\\.mkv$`).test(request.file));
	if (!valid) return;
	const player = players.get(request.key);
	if (player === undefined) {
		send(connection, { reply: { id: request.id, error: 'The player window is gone' } });
		return;
	}
	waiting.set(request.id, connection);
	global.postMessage(player, kind, request);
});

global.onMessage('reply', (reply) => {
	const connection = waiting.get(reply?.id);
	if (!connection) return;
	waiting.delete(reply.id);
	send(connection, { reply });
});

ws.onStateUpdate((state, error) => {
	if (state === 'failed') console.log(`The WebSocket server failed: ${error?.description ?? ''}`);
});
ws.createServer({ port: Number(preferences.get('port')) || 6680 });
ws.startServer();
