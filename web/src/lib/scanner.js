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
	const source = textSourceGenerator.getRangeFromPoint(x, y, {
		deepContentScan: false,
		normalizeCssZoom: true,
		language: getSettings().language,
		browser: 'safari',
	});
	if (source instanceof TextSourceRange && getSettings().scanResolution === 'word') expandToWordStart(source);
	return source;
}

// The languages Yomitan doesn't use word scan resolution for (TextScanner's
// SCAN_RESOLUTION_EXCLUDED_LANGUAGES). Most don't separate words with spaces, so the word would reach
// back to the start of the sentence.
const wordResolutionExcludedLanguages = new Set(['ja', 'zh', 'yue', 'ko']);

/** Yomitan's word scan resolution: the scan starts at the beginning of the word under the cursor. */
function expandToWordStart(source) {
	if (wordResolutionExcludedLanguages.has(getSettings().language)) return;
	source.setStartOffset(getSettings().scanLength, false, true);
}

/**
 * Looks up the text at `textSource` (terms first, then kanji, like Yomitan's TextScanner).
 * On success `textSource` is narrowed to the matched text.
 */
export async function searchTextSource(textSource, { searchTerms = true, searchKanji = true } = {}) {
	const { scanLength, sentenceScanExtent, sentenceTerminationCharacterMode, sentenceTerminationCharacters } = getSettings();
	const scanSource = textSource.clone();
	scanSource.setEndOffset(scanLength, false, false);
	const fullQuery = scanSource.text();
	if (fullQuery.trim().length === 0) return null;

	let type = 'term';
	let dictionaryEntries;
	let matchLength;
	// Scan inputs can look up only terms or only kanji (see lib/scan-inputs.js).
	const termResult = searchTerms ? await termEntries(fullQuery) : { dictionaryEntries: [] };
	if (termResult.dictionaryEntries.length > 0) {
		dictionaryEntries = termResult.dictionaryEntries;
		matchLength = termResult.originalTextLength;
	} else {
		if (!searchKanji) return null;
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
	// Yomitan's "Select matched text".
	if (textSource?.range && getSettings().selectMatchedText) {
		for (const range of textRanges(textSource.range)) highlight.add(range);
	}
}

/**
 * Puts the base text of ruby elements under `root` in <rb> elements: WebKit doesn't paint highlights
 * on text directly in a <ruby>.
 */
export function wrapRubyBases(root) {
	for (const ruby of root.querySelectorAll('ruby')) {
		for (const node of [...ruby.childNodes]) {
			if (node.nodeType !== Node.TEXT_NODE || node.data.trim().length === 0) continue;
			const rb = document.createElement('rb');
			ruby.replaceChild(rb, node);
			rb.append(node);
		}
	}
}

/** The text of `range` as one range per text node, without the furigana, which wasn't matched. */
function textRanges(range) {
	const root = range.commonAncestorContainer;
	if (root.nodeType === Node.TEXT_NODE) return [range.cloneRange()];
	const ranges = [];
	const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
		acceptNode: (node) => (node.parentElement?.closest('rt, rp') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
	});
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		if (!range.intersectsNode(node)) continue;
		const part = document.createRange();
		part.setStart(node, node === range.startContainer ? range.startOffset : 0);
		part.setEnd(node, node === range.endContainer ? range.endOffset : node.length);
		if (!part.collapsed) ranges.push(part);
	}
	return ranges;
}
