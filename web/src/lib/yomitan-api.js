// Client for https://github.com/yomidevs/yomitan-api
import { httpPost, nativeCall } from './native.js';
import { getSettings } from './settings.js';

// For the Yomitan API's status on the menu bar icon (see YomitanAPIStatus.swift).
function reportRequest(succeeded) {
	nativeCall('yomitanApiRequest', { succeeded }).catch(() => {});
}

/** A request the API answered 504: it reached Yomitan (or its turn), which didn't answer in time. */
export class YomitanAPITimeout extends Error {}

async function call(path, body = {}, signal = null) {
	const { yomitanApiUrl } = getSettings();
	let response;
	try {
		response = await httpPost(`${yomitanApiUrl.replace(/\/+$/, '')}/${path}`, body, { signal });
	} catch (e) {
		if (!signal?.aborted) reportRequest(false);
		throw e;
	}
	const { status, body: text } = response;
	// A 504 is a slow request, not an API that's gone; a 503 (from OwOtan's app) is the API off or Safari not running.
	reportRequest(status === 200 || status === 504);
	if (status !== 200) {
		const Failure = status === 504 ? YomitanAPITimeout : Error;
		throw new Failure(`Yomitan API /${path} failed (${status})${text ? `: ${text.slice(0, 300)}` : ''}`);
	}
	return JSON.parse(text);
}

/** Aborting `signal` (for a line that's gone) drops the request if it's still waiting its turn. */
export async function tokenize(text, signal = null) {
	const { scanLength, parser } = getSettings();
	const results = await call('tokenize', { text, scanLength, parser }, signal);
	return results.find((result) => result.index === 0) ?? results[0] ?? null;
}

/** @returns {Promise<{dictionaryEntries: object[], originalTextLength: number}>} */
export function termEntries(term) {
	return call('termEntries', { term });
}

/** @returns {Promise<object[]>} */
export function kanjiEntries(character) {
	return call('kanjiEntries', { character });
}

export function ankiCardFormats() {
	return call('ankiCardFormats', {});
}

/**
 * Renders Anki handlebars markers for the dictionary entries found for `text`.
 * @returns {Promise<{fields: Record<string, string>[], dictionaryMedia: object[], audioMedia: object[]}>}
 */
export function ankiFields({ text, type, markers, maxEntries, includeMedia }) {
	return call('ankiFields', { text, type, markers, maxEntries, includeMedia });
}
