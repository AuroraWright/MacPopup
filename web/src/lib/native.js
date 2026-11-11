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

/** Aborting `signal` closes the request's connection, and the promise rejects with the signal's reason. */
export async function httpPost(url, body, { timeout = 30, signal = null } = {}) {
	if (!signal) return nativeCall('http', { url, body: JSON.stringify(body), timeout });
	signal.throwIfAborted();
	// (Each frame's own counter would repeat another's.)
	const id = Math.random().toString(36).slice(2);
	const cancel = () => nativeCall('cancelHttp', { id }).catch(() => {});
	signal.addEventListener('abort', cancel, { once: true });
	try {
		return await nativeCall('http', { url, body: JSON.stringify(body), timeout, id });
	} catch (e) {
		signal.throwIfAborted();
		throw e;
	} finally {
		signal.removeEventListener('abort', cancel);
	}
}

export function log(...args) {
	const message = args.map((arg) => (arg instanceof Error ? arg.stack || arg.message : typeof arg === 'string' ? arg : JSON.stringify(arg))).join(' ');
	nativeCall('log', { message }).catch(() => {});
}
