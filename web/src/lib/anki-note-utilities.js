// Stands in for Yomitan's utilities (ext/js/core/utilities.js) in its Anki note data
// (ext/js/data/anki-note-data-creator.js). The note data for each field scopes the dictionary styles
// of every definition again, parsing them as a stylesheet twice (even for {expression}), which adds
// milliseconds to each field of each entry. This keeps the last result for each scope instead.

import { addScopeToCssLegacy as addScopeToCssLegacyUncached } from '../../../vendor/yomitan/ext/js/core/utilities.js';

export * from '../../../vendor/yomitan/ext/js/core/utilities.js';

/** @type {Map<string, {css: string, result: string}>} scope -> the last styles scoped to it */
const scopedStyles = new Map();

/**
 * @param {string} css
 * @param {string} scopeSelector
 * @returns {string}
 */
export function addScopeToCssLegacy(css, scopeSelector) {
	const cached = scopedStyles.get(scopeSelector);
	if (cached?.css === css) return cached.result;
	const result = addScopeToCssLegacyUncached(css, scopeSelector);
	scopedStyles.set(scopeSelector, { css, result });
	return result;
}
