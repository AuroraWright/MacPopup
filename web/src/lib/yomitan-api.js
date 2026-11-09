// Client for https://github.com/yomidevs/yomitan-api
import { httpPost, nativeCall } from './native.js';
import { getSettings } from './settings.js';

// For the Yomitan API's status on the menu bar icon (see YomitanAPIStatus.swift).
function reportRequest(succeeded) {
	nativeCall('yomitanApiRequest', { succeeded }).catch(() => {});
}

async function call(path, body = {}) {
	const { yomitanApiUrl } = getSettings();
	let response;
	try {
		response = await httpPost(`${yomitanApiUrl.replace(/\/+$/, '')}/${path}`, body);
	} catch (e) {
		reportRequest(false);
		throw e;
	}
	const { status, body: text } = response;
	reportRequest(status === 200);
	if (status !== 200) {
		throw new Error(`Yomitan API /${path} failed (${status})${text ? `: ${text.slice(0, 300)}` : ''}`);
	}
	return JSON.parse(text);
}

export function yomitanVersion() {
	return call('yomitanVersion');
}

export async function tokenize(text) {
	const { scanLength, parser } = getSettings();
	const results = await call('tokenize', { text, scanLength, parser });
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
