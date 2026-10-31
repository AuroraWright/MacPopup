// Text scanning built on Yomitan's own DOM text-source code, so lookups, matched ranges and
// sentence extraction behave like Yomitan's. Each bundle (overlay, popup) operates on its own document.
import { TextSourceGenerator } from '../../../vendor/yomitan/ext/js/dom/text-source-generator.js';
import { TextSourceRange } from '../../../vendor/yomitan/ext/js/dom/text-source-range.js';
import { getSettings } from './settings.js';
import { kanjiEntries, termEntries } from './yomitan-api.js';

// Same as Yomitan's TextScanner.setOptions.
let terminatorMaps = null;
function getTerminatorMaps(mode, characters) {
	if (terminatorMaps?.mode === mode && terminatorMaps.characters === characters) return terminatorMaps;
	const terminatorMap = new Map();
	const forwardQuoteMap = new Map();
	const backwardQuoteMap = new Map();
	if (Array.isArray(characters) && (mode === 'custom' || mode === 'custom-no-newlines')) {
		for (const { enabled, character1, character2, includeCharacterAtStart, includeCharacterAtEnd } of characters) {
			if (!enabled) continue;
			if (character2 === null) {
				terminatorMap.set(character1, [includeCharacterAtStart, includeCharacterAtEnd]);
			} else {
				forwardQuoteMap.set(character1, [character2, includeCharacterAtStart]);
				backwardQuoteMap.set(character2, [character1, includeCharacterAtEnd]);
			}
		}
	}
	terminatorMaps = { mode, characters, terminatorMap, forwardQuoteMap, backwardQuoteMap };
	return terminatorMaps;
}

const textSourceGenerator = new TextSourceGenerator();

export const HIGHLIGHT_NAME = 'macpopup-scan';

export function getTextSourceFromPoint(x, y) {
	return textSourceGenerator.getRangeFromPoint(x, y, {
		deepContentScan: false,
		normalizeCssZoom: true,
		language: 'ja',
		browser: 'safari',
	});
}

/** A collapsed text source at the start of `node`, skipping ruby annotations. */
export function getTextSourceAtElementStart(element) {
	const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, {
		acceptNode: (node) => (node.parentElement?.closest('rt, rp') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
	});
	const node = walker.nextNode();
	if (!node) return null;
	const range = document.createRange();
	range.setStart(node, 0);
	range.setEnd(node, 0);
	return TextSourceRange.create(range);
}

/**
 * Looks up the text at `textSource` (terms first, then kanji, like Yomitan's TextScanner).
 * On success `textSource` is narrowed to the matched text.
 */
export async function searchTextSource(textSource) {
	const { scanLength, sentenceScanExtent, sentenceTerminationCharacterMode, sentenceTerminationCharacters } = getSettings();
	const scanSource = textSource.clone();
	scanSource.setEndOffset(scanLength, false, false);
	const fullQuery = scanSource.text();
	if (fullQuery.trim().length === 0) return null;

	let type = 'term';
	let dictionaryEntries;
	let matchLength;
	const termResult = await termEntries(fullQuery);
	if (termResult.dictionaryEntries.length > 0) {
		dictionaryEntries = termResult.dictionaryEntries;
		matchLength = termResult.originalTextLength;
	} else {
		const character = String.fromCodePoint(fullQuery.codePointAt(0));
		dictionaryEntries = await kanjiEntries(character);
		if (!Array.isArray(dictionaryEntries) || dictionaryEntries.length === 0) return null;
		type = 'kanji';
		matchLength = 1;
	}

	textSource.setEndOffset(matchLength, false, false);
	const query = textSource.text();
	const { terminatorMap, forwardQuoteMap, backwardQuoteMap } = getTerminatorMaps(sentenceTerminationCharacterMode, sentenceTerminationCharacters);
	const sentence = textSourceGenerator.extractSentence(
		textSource,
		false,
		sentenceScanExtent,
		sentenceTerminationCharacterMode === 'custom' || sentenceTerminationCharacterMode === 'newlines',
		terminatorMap,
		forwardQuoteMap,
		backwardQuoteMap,
	);
	return { type, dictionaryEntries, query, fullQuery, sentence };
}

// One Highlight stays registered and only its ranges change: WebKit doesn't repaint text whose
// highlight is removed with CSS.highlights.delete() or replaced with set(), so it would stay visible.
let highlight = null;

export function setHighlight(textSource) {
	if (typeof CSS === 'undefined' || !CSS.highlights) return;
	if (highlight === null) {
		highlight = new Highlight();
		CSS.highlights.set(HIGHLIGHT_NAME, highlight);
	}
	highlight.clear();
	if (textSource?.range) highlight.add(textSource.range.cloneRange());
}
