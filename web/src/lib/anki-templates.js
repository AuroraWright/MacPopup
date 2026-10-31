// Renders Anki field templates in the popup with Yomitan's own renderer, from the templates in
// Settings (copied by Import Yomitan), with the same data the Yomitan API uses plus the popup selection. The API renders
// fields without a page, so templates that read the selection (`getMedia "popupSelectionText"`, e.g.
// to pick a dictionary by selecting its name) only work here. Settings → Anki turns this on.
import { sanitizeCSS } from '../../../vendor/yomitan/ext/js/core/utilities.js';
import { createFuriganaHtml, createFuriganaPlain } from '../../../vendor/yomitan/ext/js/data/anki-note-builder.js';
import { getDynamicTemplates } from '../../../vendor/yomitan/ext/js/data/anki-template-util.js';
import { AnkiTemplateRenderer } from '../../../vendor/yomitan/ext/js/templates/anki-template-renderer.js';
import defaultFieldTemplates from '../../../vendor/yomitan/ext/data/templates/default-anki-field-templates.handlebars';
import { log } from './native.js';
import { getSettings } from './settings.js';

let rendererPromise = null;
const sanitizedStyles = new Map();

function getRenderer() {
	rendererPromise ??= (async () => {
		const renderer = new AnkiTemplateRenderer(document, window);
		await renderer.prepare();
		return renderer;
	})();
	return rendererPromise;
}

/** Whether fields should be rendered here instead of by the API. */
export function shouldRenderLocally() {
	return getSettings().ankiRenderTemplatesLocally;
}

// Like YomitanApi._getAnkiTemplate. Every dictionary gets its single-dictionary markers, since the
// term and frequency counts that Yomitan checks aren't known here. The entry's own dictionaries are
// included for templates set up without an import.
function getTemplate({ fieldTemplates, dictionaries: importedDictionaries }, dictionaryEntry) {
	const dictionaries = [...new Set([...importedDictionaries, ...getEntryDictionaries(dictionaryEntry)])];
	const options = { dictionaries: dictionaries.map((name) => ({ name, enabled: true })) };
	const dictionaryInfo = dictionaries.map((title) => ({ title, counts: { terms: { total: 1 }, termMeta: { freq: 1 } } }));
	return `${fieldTemplates ?? defaultFieldTemplates}\n${getDynamicTemplates(options, dictionaryInfo)}`;
}

function getEntryDictionaries(dictionaryEntry) {
	// Kanji entries name their dictionary themselves, and their definitions are plain strings.
	const names = [dictionaryEntry.dictionary];
	for (const key of ['definitions', 'frequencies', 'pronunciations']) {
		for (const item of dictionaryEntry[key] ?? []) names.push(item?.dictionary);
	}
	return names.filter((name) => typeof name === 'string');
}

function getDictionaryStylesMap() {
	const map = new Map();
	for (const { name, styles } of getSettings().dictionaryStyles ?? []) {
		if (!sanitizedStyles.has(styles)) {
			let css = '';
			try {
				css = sanitizeCSS(styles).replaceAll(/(\r|\n)/g, ' ');
			} catch (_) {
				// Yomitan leaves out styles that don't parse.
			}
			sanitizedStyles.set(styles, css);
		}
		map.set(name, sanitizedStyles.get(styles));
	}
	return map;
}

// The data YomitanApi._createCommonDatas builds, with the popup selection added.
function createCommonData({ dictionaryEntry, query, apiResult, selectionText, imported }) {
	const settings = getSettings();
	const dictionaryMedia = {};
	for (const { dictionary, path, ankiFilename } of apiResult?.dictionaryMedia ?? []) {
		(dictionaryMedia[dictionary] ??= {})[path] = { value: ankiFilename };
	}
	let audioFilename = '';
	let furiganaData = [];
	if (dictionaryEntry.type === 'term') {
		const [{ term, reading }] = dictionaryEntry.headwords;
		audioFilename = (apiResult?.audioMedia ?? []).find((item) => item.term === term && item.reading === reading)?.ankiFilename ?? '';
		furiganaData = [[{ text: term, reading }]];
	}
	const readingMode = imported.readingMode === 'hiragana' || imported.readingMode === 'katakana' ? imported.readingMode : null;
	return {
		dictionaryEntry,
		resultOutputMode: imported.resultOutputMode,
		cardFormat: { type: 'term', name: '', deck: '', model: '', fields: {}, icon: 'big-circle' },
		glossaryLayoutMode: settings.glossaryLayoutMode,
		compactTags: settings.compactTags,
		context: { url: '', documentTitle: '', query, fullQuery: query, sentence: { text: '', offset: 0 } },
		media: {
			audio: audioFilename.length > 0 ? { value: audioFilename } : undefined,
			popupSelectionText: { value: selectionText },
			textFurigana: [
				{
					text: query,
					readingMode,
					detailsHtml: { value: createFuriganaHtml(furiganaData, readingMode, null) },
					detailsPlain: { value: createFuriganaPlain(furiganaData, readingMode, null) },
				},
			],
			dictionaryMedia,
		},
		dictionaryStylesMap: getDictionaryStylesMap(),
	};
}

/**
 * Renders `markers` for one dictionary entry. A marker that fails to render is left out, so the
 * API's value is used for it.
 * @param {{markers: string[], dictionaryEntry: object, query: string, apiResult: ?object, selectionText: string}} details
 *   `apiResult` is the API's /ankiFields response with media, whose file names are reused.
 * @returns {Promise<Record<string, string>>}
 */
export async function renderFields({ markers, dictionaryEntry, query, apiResult, selectionText }) {
	// Yomitan's defaults until Import Yomitan or Settings sets the templates.
	const imported = getSettings().yomitanAnkiTemplates ?? { fieldTemplates: null, dictionaries: [], resultOutputMode: 'group', readingMode: null };
	const renderer = await getRenderer();
	const template = getTemplate(imported, dictionaryEntry);
	const commonData = createCommonData({ dictionaryEntry, query, apiResult, selectionText, imported });
	const fields = {};
	for (const marker of markers) {
		try {
			fields[marker] = renderer.templateRenderer.render(template, { marker, commonData }, 'ankiNote').result;
		} catch (e) {
			log(`Rendering {${marker}} with the field templates from Settings failed: ${e?.message ?? e}`);
		}
	}
	return fields;
}
