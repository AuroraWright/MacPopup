import { httpPost } from './native.js';
import { getSettings } from './settings.js';

export async function ankiInvoke(action, params = {}) {
	const { ankiConnectUrl, ankiConnectKey } = getSettings();
	const body = { action, version: 6, params };
	if (ankiConnectKey) body.key = ankiConnectKey;
	let response;
	try {
		response = await httpPost(ankiConnectUrl, body);
	} catch (_) {
		throw new Error('Anki not connected');
	}
	const result = JSON.parse(response.body);
	if (result && typeof result === 'object' && 'error' in result) {
		if (result.error) throw new Error(result.error);
		return result.result;
	}
	return result;
}

export function getRootDeckName(deckName) {
	const index = deckName.indexOf('::');
	return index >= 0 ? deckName.substring(0, index) : deckName;
}

// Same duplicate query Yomitan builds in comm/anki-connect.js.
function escapeQuery(text) {
	return text.replace(/"/g, '');
}

export function getNoteQuery(note) {
	let query = '';
	switch (note.options?.duplicateScope) {
		case 'deck':
			query = `"deck:${escapeQuery(note.deckName)}" `;
			break;
		case 'deck-root':
			query = `"deck:${escapeQuery(getRootDeckName(note.deckName))}" `;
			break;
	}
	const [key] = Object.keys(note.fields);
	if (key) query += `"${key.toLowerCase()}:${escapeQuery(note.fields[key])}"`;
	return query;
}

export async function findNoteIds(notes) {
	const queries = [...new Set(notes.map(getNoteQuery))];
	const results = await ankiInvoke('multi', { actions: queries.map((query) => ({ action: 'findNotes', params: { query } })) });
	const byQuery = new Map();
	queries.forEach((query, i) => {
		const result = results[i];
		byQuery.set(query, Array.isArray(result) ? result : Array.isArray(result?.result) ? result.result : []);
	});
	return notes.map((note) => byQuery.get(getNoteQuery(note)) ?? []);
}
