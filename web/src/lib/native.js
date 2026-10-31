// Bridge to the Swift host (Sources/MacPopup/NativeBridge.swift).

function getHandler() {
	let win = window;
	while (win) {
		const handler = win.webkit?.messageHandlers?.native;
		if (handler) return handler;
		if (win.parent === win) break;
		win = win.parent;
	}
	return null;
}

export function nativeCall(cmd, args = {}) {
	const handler = getHandler();
	if (!handler) return Promise.reject(new Error('Native bridge unavailable'));
	return handler.postMessage({ cmd, ...args });
}

export async function httpPost(url, body, timeout = 30) {
	return nativeCall('http', { url, body: JSON.stringify(body), timeout });
}

export function log(...args) {
	const message = args.map((arg) => (arg instanceof Error ? arg.stack || arg.message : typeof arg === 'string' ? arg : JSON.stringify(arg))).join(' ');
	nativeCall('log', { message }).catch(() => {});
}
