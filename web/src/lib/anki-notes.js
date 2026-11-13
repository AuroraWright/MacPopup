// Builds Anki notes the way Yomitan does, with handlebars rendered by the Yomitan API (`/ankiFields`),
// or by lib/anki-templates.js when Settings → Anki says to render the imported templates.
// The API has no page context, so markers that depend on it (sentence, cloze, screenshot, clipboard, …)
// are filled in here, following Yomitan's default templates.
import { createFuriganaHtml, createFuriganaPlain } from '../../../vendor/yomitan/ext/js/data/anki-note-builder.js';
import { distributeFuriganaInflected } from '../../../vendor/yomitan/ext/js/language/ja/japanese.js';
import { ankiInvoke, getRootDeckName } from './anki-connect.js';
import { ankiReadingMode, renderFields, shouldRenderLocally } from './anki-templates.js';
import { log, nativeCall } from './native.js';
import { getSettings } from './settings.js';
import { ankiFields, tokenize } from './yomitan-api.js';

const markerPattern = /\{([\p{Letter}\p{Number}_-]+)\}/gu;

const localMarkers = new Set([
	'sentence',
	'cloze-prefix',
	'cloze-body',
	'cloze-body-kana',
	'cloze-suffix',
	'sentence-furigana',
	'sentence-furigana-plain',
	'document-title',
	'url',
	'url-plain',
	'popup-selection-text',
	'clipboard-text',
	'clipboard-image',
	'screenshot',
]);

// Markers that need I/O and are left empty when only checking for duplicates.
const deferredMarkers = new Set(['sentence-furigana', 'sentence-furigana-plain', 'document-title', 'clipboard-text', 'clipboard-image', 'screenshot']);

function getFieldMarkers(value) {
	return [...value.matchAll(markerPattern)].map((match) => match[1]);
}

function formatField(value, getMarkerValue) {
	return value.replace(markerPattern, (_, marker) => getMarkerValue(marker) ?? '');
}

function unique(values) {
	return [...new Set(values)];
}

function getPrimarySource(dictionaryEntry) {
	for (const headword of dictionaryEntry.headwords) {
		for (const source of headword.sources) {
			if (source.isPrimary) return source;
		}
	}
	return null;
}

// Port of getCloze() from Yomitan's data/anki-note-data-creator.js.
function getCloze(dictionaryEntry, sentence) {
	let originalText = '';
	let term = '';
	let reading = '';
	if (dictionaryEntry.type === 'term') {
		term = dictionaryEntry.headwords[0].term;
		reading = dictionaryEntry.headwords[0].reading;
		originalText = getPrimarySource(dictionaryEntry)?.originalText ?? '';
	} else {
		originalText = dictionaryEntry.character;
	}
	const text = typeof sentence?.text === 'string' ? sentence.text : '';
	const offset = typeof sentence?.offset === 'number' ? sentence.offset : 0;
	const textChars = [...text];
	const body = textChars.slice(offset, offset + originalText.length).join('');
	const bodyKana = distributeFuriganaInflected(term, reading, body)
		.map(({ text: text2, reading: reading2 }) => (reading2.length > 0 ? reading2 : text2))
		.join('');
	return {
		sentence: textChars.join(''),
		prefix: textChars.slice(0, offset).join(''),
		body,
		bodyKana,
		suffix: textChars.slice(offset + originalText.length).join(''),
	};
}

function timestamp() {
	const date = new Date();
	const pad = (value, length = 2) => `${value}`.padStart(length, '0');
	return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}-${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}-${pad(date.getMilliseconds(), 3)}`;
}

/**
 * Resolves page-context markers.
 * @returns {Promise<{values: Map<string, string>, media: {filename: string, data: string}[]}>}
 */
async function resolveLocalMarkers(markers, { dictionaryEntry, content, selectionText, deferred }) {
	const values = new Map();
	const media = [];
	const cloze = getCloze(dictionaryEntry, content.sentence);
	const settings = getSettings();

	await Promise.all(
		markers.map(async (marker) => {
			if (!deferred && deferredMarkers.has(marker)) {
				values.set(marker, '');
				return;
			}
			switch (marker) {
				case 'sentence':
					values.set(marker, cloze.sentence);
					break;
				case 'cloze-prefix':
					values.set(marker, cloze.prefix);
					break;
				case 'cloze-body':
					values.set(marker, cloze.body);
					break;
				case 'cloze-body-kana':
					values.set(marker, cloze.bodyKana);
					break;
				case 'cloze-suffix':
					values.set(marker, cloze.suffix);
					break;
				case 'sentence-furigana':
				case 'sentence-furigana-plain': {
					let value = cloze.sentence;
					try {
						const parsed = cloze.sentence ? await tokenize(cloze.sentence) : null;
						if (parsed) {
							const readingMode = ankiReadingMode(getSettings());
							value = marker === 'sentence-furigana' ? createFuriganaHtml(parsed.content, readingMode, null) : createFuriganaPlain(parsed.content, readingMode, null);
						}
					} catch (_) {
						// Fall back to the plain sentence, like Yomitan does when parsing fails.
					}
					values.set(marker, value);
					break;
				}
				case 'document-title':
					values.set(marker, content.documentTitle ?? '');
					break;
				case 'url':
				case 'url-plain':
					values.set(marker, '');
					break;
				case 'popup-selection-text':
					values.set(marker, selectionText ?? '');
					break;
				case 'clipboard-text': {
					const { text } = await nativeCall('clipboard');
					values.set(marker, text ?? '');
					break;
				}
				case 'clipboard-image': {
					const { image } = await nativeCall('clipboard', { image: true });
					if (image) {
						const filename = `yomitan_clipboard_image_${timestamp()}.png`;
						media.push({ filename, data: image });
						values.set(marker, `<img src="${filename}" />`);
					} else {
						values.set(marker, '');
					}
					break;
				}
				case 'screenshot': {
					const format = settings.screenshotFormat === 'png' ? 'png' : 'jpeg';
					const data = await takeScreenshot(content.player, format, settings);
					const filename = `yomitan_screenshot_${timestamp()}.${format === 'png' ? 'png' : 'jpg'}`;
					media.push({ filename, data });
					values.set(marker, `<img src="${filename}" />`);
					break;
				}
			}
		}),
	);
	return { values, media };
}

/** Whether a video player's line has a source for `track` ('video' or 'audio') and its timing. */
function hasPlayerTrack(player, track) {
	return !!player?.[track] && typeof player[track] === 'object' && typeof player.start === 'number' && typeof player.end === 'number';
}

/**
 * For a video player's line (content.player, see iina-plugin/), the frame in the middle of the line, from the video
 * file or stream; else the captured window or display.
 */
async function takeScreenshot(player, format, settings) {
	if (hasPlayerTrack(player, 'video')) {
		try {
			const time = (player.start + player.end) / 2;
			return await nativeCall('mediaFrame', { source: player.video, socket: player.socket, time, format, quality: settings.screenshotQuality });
		} catch (e) {
			log('The line’s screenshot failed', e);
		}
	}
	return nativeCall('screenshot', { format, quality: settings.screenshotQuality, resolution: settings.screenshotResolution });
}

/**
 * The sentence audio of a video player's line (content.player, see iina-plugin/): its time range with the padding
 * of Settings → IINA Integration, cut out of the video file or stream, for the sentence audio field when it's empty.
 */
async function playerSentenceAudio(player, cardFormat, fields) {
	const settings = getSettings();
	const field = settings.sentenceAudioField?.trim();
	if (!settings.iinaSentenceAudioEnabled || !field || !(field in cardFormat.fields) || fields[field]) return null;
	if (!hasPlayerTrack(player, 'audio')) return null;
	const padding = (settings.iinaSentenceAudioPadding ?? 500) / 1000;
	try {
		const data = await nativeCall('mediaClip', {
			source: player.audio,
			socket: player.socket,
			start: Math.max(0, player.start - padding),
			end: player.end + padding,
		});
		return { field, filename: `macpopup_sentence_${timestamp()}.m4a`, data };
	} catch (e) {
		log('The sentence audio failed', e);
		return null;
	}
}

function createNoteOptions(cardFormat) {
	const settings = getSettings();
	let duplicateScope = settings.duplicateScope;
	let deckName = null;
	let checkChildren = false;
	if (duplicateScope === 'deck-root') {
		duplicateScope = 'deck';
		deckName = getRootDeckName(cardFormat.deck);
		checkChildren = true;
	}
	return {
		allowDuplicate: true,
		duplicateScope,
		duplicateScopeOptions: { deckName, checkChildren, checkAllModels: settings.duplicateScopeCheckAllModels },
	};
}

function getTags() {
	return getSettings()
		.ankiTags.split(/[,\s]+/)
		.filter((tag) => tag.length > 0);
}

/**
 * Renders the first field of each card format for every entry, for duplicate checks. Rendering the
 * field templates takes up to tens of milliseconds an entry, so the page's other work gets turns in
 * between, and it stops (null) once `isCanceled` says so.
 * @param {() => boolean} [isCanceled]
 * @returns {Promise<?{entryIndex: number, cardFormatIndex: number, note: object}[]>}
 */
export async function buildFirstFieldNotes(content, cardFormats, cardFormatIndices, isCanceled = () => false) {
	const firstFields = cardFormatIndices.map((cardFormatIndex) => {
		const cardFormat = cardFormats[cardFormatIndex];
		const [name] = Object.keys(cardFormat.fields);
		return { cardFormatIndex, cardFormat, name, value: name ? cardFormat.fields[name].value : '' };
	});
	const markers = unique(firstFields.flatMap(({ value }) => getFieldMarkers(value)));
	const apiMarkers = markers.filter((marker) => !localMarkers.has(marker));
	const renderLocally = shouldRenderLocally();
	const rendered = apiMarkers.length && !renderLocally
		? await ankiFields({
				text: content.query,
				type: content.type,
				markers: apiMarkers,
				maxEntries: content.dictionaryEntries.length,
				includeMedia: false,
			})
		: { fields: [] };

	const results = [];
	let sliceStart = performance.now();
	for (let entryIndex = 0; entryIndex < content.dictionaryEntries.length; ++entryIndex) {
		if (performance.now() - sliceStart > 15) {
			await new Promise((resolve) => setTimeout(resolve, 0));
			sliceStart = performance.now();
		}
		if (isCanceled()) return null;
		const { values } = await resolveLocalMarkers(
			markers.filter((marker) => localMarkers.has(marker)),
			{ dictionaryEntry: content.dictionaryEntries[entryIndex], content, deferred: false },
		);
		const dictionaryEntry = content.dictionaryEntries[entryIndex];
		const renderedFields = renderLocally
			? await renderFields({ markers: apiMarkers, dictionaryEntry, query: content.query, apiResult: null, selectionText: '' })
			: (rendered.fields[entryIndex] ?? {});
		for (const { cardFormatIndex, cardFormat, name, value } of firstFields) {
			const fields = {};
			if (name) {
				fields[name] = formatField(value, (marker) => (marker in renderedFields ? renderedFields[marker] : values.get(marker)));
			}
			results.push({
				entryIndex,
				cardFormatIndex,
				note: {
					deckName: cardFormat.deck,
					modelName: cardFormat.model,
					fields,
					options: { duplicateScope: getSettings().duplicateScope },
				},
			});
		}
	}
	return results;
}

const audioExtensions = {
	'audio/mpeg': 'mp3',
	'audio/mp3': 'mp3',
	'audio/mp4': 'm4a',
	'audio/aac': 'aac',
	'audio/ogg': 'ogg',
	'audio/opus': 'opus',
	'audio/wav': 'wav',
	'audio/x-wav': 'wav',
	'audio/webm': 'webm',
	'audio/flac': 'flac',
};

/** FNV-1a, to name a media file after its contents. */
function hashString(text) {
	let hash = 0x811c9dc5;
	for (let i = 0; i < text.length; ++i) {
		hash ^= text.charCodeAt(i);
		hash = Math.imul(hash, 0x01000193);
	}
	return (hash >>> 0).toString(16).padStart(8, '0');
}

/**
 * Puts the audio chosen in the play button menu in place of the audio the API fetched for the same
 * word (which is the first its sources have). Returns the file name to replace in fields, if any.
 */
function overrideAudio(api, override) {
	const item = (api?.audioMedia ?? []).find(({ term, reading }) => term === override.term && reading === override.reading);
	if (!item) return null;
	const type = override.contentType.split(';')[0].trim().toLowerCase();
	const filename = `yomitan_audio_${hashString(override.data)}.${audioExtensions[type] ?? 'mp3'}`;
	const replaced = { from: item.ankiFilename, to: filename };
	item.ankiFilename = filename;
	item.content = override.data;
	return replaced;
}

/**
 * Builds the complete note for one entry and card format.
 * @param {?{term: string, reading: string, data: string, contentType: string}} audioOverride Audio chosen
 *   in the play button menu, used instead of the API's.
 */
export async function buildNote({ content, entryIndex, cardFormat, selectionText, audioOverride = null }) {
	const fieldEntries = Object.entries(cardFormat.fields);
	const markers = unique(fieldEntries.flatMap(([, { value }]) => getFieldMarkers(value)));
	const apiMarkers = markers.filter((marker) => !localMarkers.has(marker));
	const dictionaryEntry = content.dictionaryEntries[entryIndex];

	const [api, local] = await Promise.all([
		apiMarkers.length
			? ankiFields({ text: content.query, type: content.type, markers: apiMarkers, maxEntries: entryIndex + 1, includeMedia: true })
			: null,
		resolveLocalMarkers(
			markers.filter((marker) => localMarkers.has(marker)),
			{ dictionaryEntry, content, selectionText, deferred: true },
		),
	]);

	const replacedAudio = audioOverride ? overrideAudio(api, audioOverride) : null;
	let rendered = api?.fields[entryIndex] ?? {};
	// The API still provides the media (dictionary images, audio) that the local templates refer to.
	if (apiMarkers.length && shouldRenderLocally()) {
		const local = await renderFields({ markers: apiMarkers, dictionaryEntry, query: content.query, apiResult: api, selectionText: selectionText ?? '' });
		rendered = { ...rendered, ...local };
	}
	const fields = {};
	for (const [name, { value }] of fieldEntries) {
		fields[name] = formatField(value, (marker) => (marker in rendered ? rendered[marker] : local.values.get(marker)));
		if (replacedAudio) fields[name] = fields[name].replaceAll(replacedAudio.from, replacedAudio.to);
	}

	const sentenceAudio = await playerSentenceAudio(content.player, cardFormat, fields);
	if (sentenceAudio) fields[sentenceAudio.field] = `[sound:${sentenceAudio.filename}]`;

	const allText = Object.values(fields).join('\n');
	const media = local.media.filter(({ filename }) => allText.includes(filename));
	for (const item of [...(api?.audioMedia ?? []), ...(api?.dictionaryMedia ?? [])]) {
		if (allText.includes(item.ankiFilename) && !media.some(({ filename }) => filename === item.ankiFilename)) {
			media.push({ filename: item.ankiFilename, data: item.content });
		}
	}
	if (sentenceAudio) media.push({ filename: sentenceAudio.filename, data: sentenceAudio.data });

	return {
		note: {
			deckName: cardFormat.deck,
			modelName: cardFormat.model,
			fields,
			tags: getTags(),
			options: createNoteOptions(cardFormat),
		},
		media,
	};
}

export async function storeMedia(media) {
	for (const { filename, data } of media) {
		await ankiInvoke('storeMediaFile', { filename, data });
	}
}

function getOverwrittenField(existingValue, newValue, overwriteMode) {
	switch (overwriteMode) {
		case 'overwrite':
			return newValue;
		case 'skip':
			return existingValue;
		case 'append':
			return existingValue + newValue;
		case 'prepend':
			return newValue + existingValue;
		case 'coalesce-new':
			return newValue || existingValue;
		case 'coalesce':
		default:
			return existingValue || newValue;
	}
}

export async function overwriteNote(noteId, note, cardFormat) {
	const [info] = await ankiInvoke('notesInfo', { notes: [noteId] });
	if (!info) throw new Error('Could not find the note to overwrite');
	const fields = {};
	for (const [name, value] of Object.entries(note.fields)) {
		const existing = info.fields?.[name]?.value ?? '';
		fields[name] = getOverwrittenField(existing, value, cardFormat.fields[name]?.overwriteMode);
	}
	// A note selected in Anki's card browser is open in its editor, and AnkiConnect doesn't change a note open in an
	// editor (older versions did, and the editor then saved its old fields over the change). So while it changes, the
	// browser shows no note, and then this one; a closed browser isn't opened. Other editors (Edit Current, AnkiConnect's
	// Edit dialog) can't be closed from here.
	const selected = await ankiInvoke('guiSelectedNotes').catch(() => []);
	const inBrowser = Array.isArray(selected) && selected.includes(noteId);
	if (inBrowser) await ankiInvoke('guiBrowse', { query: 'nid:1' }).catch(() => {});
	try {
		await ankiInvoke('updateNoteFields', { note: { id: noteId, fields } });
	} finally {
		if (inBrowser) await ankiInvoke('guiBrowse', { query: `nid:${noteId}` }).catch(() => {});
	}
}
