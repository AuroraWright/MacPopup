// Stands in for Yomitan's RequestBuilder (ext/js/background/request-builder.js), which needs extension
// APIs, for its AudioDownloader. Requests go through the app, so they aren't subject to CORS (e.g. a
// local audio server).

import { nativeCall } from './native.js';

export class RequestBuilder {
	/**
	 * @param {string} url
	 * @param {RequestInit} init
	 * @returns {Promise<Response>}
	 */
	async fetchAnonymous(url, init = {}) {
		// As fetch() would: non-ASCII characters (e.g. the word in a custom URL) are percent-encoded.
		const href = new URL(url).href;
		// AudioDownloader aborts downloads that stay idle too long (its idle timeout). The whole response
		// arrives at once here, so that's the time until it does.
		const request = nativeCall('http', { url: href, method: init.method ?? 'GET', binary: true, timeout: 60 });
		const { signal } = init;
		const { status, body, contentType } = signal
			? await new Promise((resolve, reject) => {
					if (signal.aborted) reject(new Error(`${signal.reason ?? 'Aborted'}`));
					signal.addEventListener('abort', () => reject(new Error(`${signal.reason ?? 'Aborted'}`)), { once: true });
					request.then(resolve, reject);
				})
			: await request;
		const bytes = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
		const headers = contentType ? { 'Content-Type': contentType } : {};
		// A Response can't have a body with these statuses.
		return new Response([101, 204, 205, 304].includes(status) ? null : bytes, { status, headers });
	}

	/**
	 * @param {Response} response
	 * @param {?(done: boolean) => void} onProgress
	 * @returns {Promise<ArrayBuffer>}
	 */
	static async readFetchResponseArrayBuffer(response, onProgress) {
		onProgress?.(false);
		const arrayBuffer = await response.arrayBuffer();
		onProgress?.(true);
		return arrayBuffer;
	}
}
