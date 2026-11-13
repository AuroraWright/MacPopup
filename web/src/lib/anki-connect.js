import { httpPost } from './native.js';
import { getSettings } from './settings.js';

export async function ankiInvoke(action, params = {}) {
	const { ankiConnectUrl, ankiConnectKey } = getSettings();
	const body = { action, version: 6, params };
	if (ankiConnectKey) {
		body.key = ankiConnectKey;
		// AnkiConnect checks the key of each of multi's actions too (as Yomitan's _invokeMulti sends them).
		if (action === 'multi') body.params = { ...params, actions: params.actions.map((subaction) => ({ ...subaction, key: ankiConnectKey })) };
	}
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

function getNoteQuery(note) {
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
		// An error fails the check rather than counting as no duplicates (e.g. an action AnkiConnect turned down).
		if (typeof result?.error === 'string') throw new Error(result.error);
		byQuery.set(query, Array.isArray(result) ? result : Array.isArray(result?.result) ? result.result : []);
	});
	return notes.map((note) => byQuery.get(getNoteQuery(note)) ?? []);
}

/**
 * The notes with their tags and cards, as Yomitan's getAnkiNoteInfo with additional info:
 * [{noteId, tags, cardsInfo: [{flags, cardState}]}] (cardState is the card's queue), null for missing notes.
 */
export async function getNoteInfos(noteIds) {
	if (noteIds.length === 0) return [];
	const notes = await ankiInvoke('notesInfo', { notes: noteIds });
	const cardIds = notes.flatMap((note) => (Array.isArray(note?.cards) ? note.cards : []));
	const cards = cardIds.length > 0 ? await ankiInvoke('cardsInfo', { cards: cardIds }) : [];
	return notes.map((note) => {
		if (!note || typeof note.noteId !== 'number') return null;
		const cardsInfo = cards
			.filter((card) => card?.note === note.noteId)
			.map(({ flags, queue }) => ({ flags: typeof flags === 'number' ? flags : 0, cardState: typeof queue === 'number' ? queue : 0 }));
		return { noteId: note.noteId, tags: Array.isArray(note.tags) ? note.tags : [], cardsInfo };
	});
}

export async function suspendCardsForNote(noteId) {
	const cards = await ankiInvoke('findCards', { query: `nid:${noteId}` });
	if (Array.isArray(cards) && cards.length > 0) await ankiInvoke('suspend', { cards });
}
