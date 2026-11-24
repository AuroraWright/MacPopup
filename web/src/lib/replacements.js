// Replacements (texthooker-ui's format): regular expressions applied to each line in order,
// [{pattern, replaces, flags: ['g', ...], enabled}]. In `replaces`, \n and \t stand for a newline and a tab.

const regexCache = new Map();

export function applyReplacements(text, replacements) {
	let result = text;
	for (const { regex, replaces } of usable(replacements)) result = result.replace(regex, replaces);
	return result;
}

/**
 * Applies the replacements as applyReplacements does, and says where the result's text came from: `sources[i]` is the
 * index in `text` of the UTF-16 unit the result's i-th one came from (for text a replacement put in, where its match
 * started).
 */
export function applyReplacementsMapped(text, replacements) {
	let result = text;
	let sources = [...Array(text.length).keys()];
	for (const { regex, replaces } of usable(replacements)) {
		let next = '';
		const nextSources = [];
		let end = 0;
		result.replace(regex, (...args) => {
			const groups = typeof args.at(-1) === 'object' ? args.pop() : undefined;
			const [match, ...captures] = args.slice(0, -2);
			const offset = args.at(-2);
			const inserted = substitution(replaces, match, captures, offset, result, groups);
			next += result.slice(end, offset) + inserted;
			nextSources.push(...sources.slice(end, offset), ...Array(inserted.length).fill(sources[offset] ?? sources.at(-1) ?? 0));
			end = offset + match.length;
			return match;
		});
		result = next + result.slice(end);
		sources = [...nextSources, ...sources.slice(end)];
	}
	return { text: result, sources };
}

/**
 * What String.prototype.replace puts in for a match (GetSubstitution): `replaces` with $$, $&, $`, $', $n, $nn and
 * $<name> filled in. (Not by replacing the match again on its own: JavaScriptCore's replace ignores a sticky regular
 * expression's lastIndex.)
 */
function substitution(replaces, match, captures, offset, text, groups) {
	return replaces.replace(/\$([$&`']|\d\d?|<[^>]*>)/g, (token, key) => {
		if (key === '$') return '$';
		if (key === '&') return match;
		if (key === '`') return text.slice(0, offset);
		if (key === "'") return text.slice(offset + match.length);
		if (key[0] === '<') return groups === undefined ? token : (groups[key.slice(1, -1)] ?? '');
		if (key.length === 2 && Number(key) >= 1 && Number(key) <= captures.length) return captures[Number(key) - 1] ?? '';
		const n = Number(key[0]);
		return n >= 1 && n <= captures.length ? (captures[n - 1] ?? '') + key.slice(1) : token;
	});
}

/** The enabled replacements whose patterns work, with their regular expressions and replacement text. */
function usable(replacements) {
	return (replacements ?? []).flatMap((replacement) => {
		if (replacement.enabled === false) return [];
		const key = `${replacement.pattern}||${(replacement.flags ?? []).join('')}`;
		let regex = regexCache.get(key);
		if (!regex) {
			try {
				regex = new RegExp(replacement.pattern, (replacement.flags ?? []).join(''));
			} catch (_) {
				return [];
			}
			regexCache.set(key, regex);
		}
		return [{ regex, replaces: (replacement.replaces ?? '').replace(/\\t/gm, '\t').replace(/\\n/gm, '\n') }];
	});
}

/** Why a pattern can't be used, or '' if it can. */
export function patternError(pattern, flags) {
	try {
		new RegExp(pattern, flags.join(''));
		return '';
	} catch (e) {
		return e.message;
	}
}
