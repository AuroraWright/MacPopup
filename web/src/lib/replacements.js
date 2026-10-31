// Replacements (texthooker-ui's format): regular expressions applied to each line in order,
// [{pattern, replaces, flags: ['g', ...], enabled}]. In `replaces`, \n and \t stand for a newline and a tab.

const regexCache = new Map();

export function applyReplacements(text, replacements) {
	let result = text;
	for (const replacement of replacements ?? []) {
		if (replacement.enabled === false) continue;
		const key = `${replacement.pattern}||${(replacement.flags ?? []).join('')}`;
		let regex = regexCache.get(key);
		if (!regex) {
			try {
				regex = new RegExp(replacement.pattern, (replacement.flags ?? []).join(''));
			} catch (_) {
				continue;
			}
			regexCache.set(key, regex);
		}
		result = result.replace(regex, (replacement.replaces ?? '').replace(/\\t/gm, '\t').replace(/\\n/gm, '\n'));
	}
	return result;
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
