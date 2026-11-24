import { httpPost, log } from './native.js';
import { getSettings } from './settings.js';

/**
 * The note type's first field (`modelFieldNames[0]`, the one Anki checks duplicates on) when the card format fills it,
 * else ''. Not the card format's first key: Chromium's native messaging sorts object keys, so in Chrome and Brave
 * the fields come alphabetically (e.g. DefinitionPicture before Expression).
 */
export function ankiFirstFieldName(fields, modelFieldNames) {
	const name = Array.isArray(modelFieldNames) ? modelFieldNames[0] : '';
	return typeof name === 'string' && name && fields && Object.prototype.hasOwnProperty.call(fields, name) ? name : '';
}

/** Note types' field names by AnkiConnect URL and note type, as {names (a promise), time}: see modelFieldNames. */
const fieldNames = new Map();

/**
 * The note type's field names, in Anki's order. Asked again after 10 s, like the card formats (see getCardFormats in
 * overlay.js), so that the popups' duplicate checks don't wait for an extra request each time. AnkiConnect's errors
 * (e.g. a note type it doesn't have) are kept as long, not a request that didn't reach it (Anki may be starting).
 */
function modelFieldNames(model) {
	const key = `${getSettings().ankiConnectUrl}\u0000${model}`;
	const cached = fieldNames.get(key);
	if (cached && Date.now() - cached.time < 10000) return cached.names;
	const names = ankiInvoke('modelFieldNames', { modelName: model });
	fieldNames.set(key, { names, time: Date.now() });
	names.catch((e) => {
		if (!e?.fromAnki && fieldNames.get(key)?.names === names) fieldNames.delete(key);
	});
	return names;
}

/**
 * The card format's note type's first field (see ankiFirstFieldName), or '' when there's none, also when Anki doesn't
 * know the note type (e.g. it was renamed or deleted): only that card format goes without notes, not the others.
 */
export async function cardFormatFirstField(cardFormat) {
	if (!cardFormat.model) return '';
	try {
		return ankiFirstFieldName(cardFormat.fields, await modelFieldNames(cardFormat.model));
	} catch (e) {
		log(`Anki note type ${cardFormat.model}'s fields:`, e);
		return '';
	}
}

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
		// (Marked as AnkiConnect's answer, unlike a request that didn't reach it.)
		if (result.error) throw Object.assign(new Error(result.error), { fromAnki: true });
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

/**
 * Each note's duplicates (see getNoteQuery), as Yomitan finds them. None for a note without its first field (a card
 * format without one, see cardFormatFirstField): an empty query would find every note in the collection or deck.
 */
export async function findNoteIds(notes) {
	const hasField = (note) => Object.keys(note.fields ?? {}).length > 0;
	const queries = [...new Set(notes.filter(hasField).map(getNoteQuery))];
	// (Still finding out whether Anki can be reached, as the search would.)
	if (queries.length === 0) {
		await ankiInvoke('version');
		return notes.map(() => []);
	}
	const results = await ankiInvoke('multi', { actions: queries.map((query) => ({ action: 'findNotes', params: { query } })) });
	const byQuery = new Map();
	queries.forEach((query, i) => {
		const result = results[i];
		// An error fails the check rather than counting as no duplicates (e.g. an action AnkiConnect turned down).
		if (typeof result?.error === 'string') throw new Error(result.error);
		byQuery.set(query, Array.isArray(result) ? result : Array.isArray(result?.result) ? result.result : []);
	});
	return notes.map((note) => (hasField(note) ? byQuery.get(getNoteQuery(note)) ?? [] : []));
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
