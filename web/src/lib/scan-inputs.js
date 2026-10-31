// Scan inputs: which keys and mouse buttons must be held for scanning. The simple modes are a
// single modifier; 'custom' uses a list of inputs like Yomitan's scanning inputs, where each input
// is a space separated combination such as "meta", "mouse3" or "ctrl mouse1" ("" scans on hover).
// A name with a leading "-" must not be held (Yomitan's "exclude"), e.g. "shift -mouse0". The word
// "terms" or "kanji" makes the input look up only terms or only kanji (Yomitan's per-input "Search terms"
// and "Search kanji"), e.g. "alt kanji"; without either it looks up both.
//
// The names are the ones Yomitan allows in scan inputs: the modifier keys meta, ctrl, alt and shift,
// and mouse buttons by their bit in MouseEvent.buttons: mouse0 (left), mouse1 (right), mouse2
// (middle), mouse3 (back), mouse4 (forward) and mouse5.

// Yomitan's sort order (HotkeyUtil.sortModifiers).
export const modifierNames = ['meta', 'ctrl', 'alt', 'shift'];

export const lookupNames = ['terms', 'kanji'];

export function isMouseButton(name) {
	return /^mouse[0-5]$/.test(name);
}

export function isValidInputName(name) {
	if (lookupNames.includes(name)) return true;
	const base = name.startsWith('-') ? name.slice(1) : name;
	return modifierNames.includes(base) || isMouseButton(base);
}

/** Input names for a MouseEvent.buttons bitmask. */
export function mouseButtonNames(buttons) {
	return [0, 1, 2, 3, 4, 5].filter((bit) => (buttons & (1 << bit)) !== 0).map((bit) => `mouse${bit}`);
}

/** "ctrl, mouse1" → ['ctrl', 'mouse1'] */
export function parseScanInput(input) {
	return `${input ?? ''}`.split(/[,\s]+/).filter(Boolean);
}

/**
 * Canonical text for a set of names, ordered like Yomitan: modifier keys, then mouse buttons, then the
 * excluded ones in the same order, then what is looked up.
 */
export function formatScanInput(names) {
	const rank = (name) => {
		if (lookupNames.includes(name)) return 200 + lookupNames.indexOf(name);
		const excluded = name.startsWith('-');
		const base = excluded ? name.slice(1) : name;
		return (excluded ? 100 : 0) + (isMouseButton(base) ? 10 + Number(base.slice(5)) : modifierNames.indexOf(base));
	};
	return [...new Set(names)].sort((a, b) => rank(a) - rank(b)).join(' ');
}

/** The input name for a KeyboardEvent.code, or null for keys that can't be used. */
export function keyNameFromCode(code) {
	const modifier = /^(Meta|Control|Alt|Shift)(Left|Right)$/.exec(code);
	return modifier ? { Meta: 'meta', Control: 'ctrl', Alt: 'alt', Shift: 'shift' }[modifier[1]] : null;
}

/**
 * The scan input that applies, like Yomitan's TextScanner: an input that requires keys or buttons
 * is active and scans right away; a hover input is passive and waits for the scan delay.
 * @param {string} mode 'none', a modifier name, or 'custom'.
 * @param {string[]} customInputs Used when mode is 'custom'.
 * @param {{shift: boolean, ctrl: boolean, alt: boolean, meta: boolean, pressed?: string[]}} state
 *   `pressed` lists the held mouse buttons.
 * @returns {?{passive: boolean, searchTerms: boolean, searchKanji: boolean}} null when no input applies.
 */
export function matchScanInput(mode, customInputs, state) {
	// Names Yomitan doesn't allow never count as held, so such an entry never triggers.
	const isHeld = (name) => (modifierNames.includes(name) ? !!state[name] : isMouseButton(name) && (state.pressed ?? []).includes(name));
	const inputs = mode === 'custom' ? (customInputs ?? []).map(parseScanInput) : [mode === 'none' ? [] : [mode]];
	let passiveMatch = null;
	for (const names of inputs) {
		const lookup = names.filter((name) => lookupNames.includes(name));
		const keys = names.filter((name) => !lookupNames.includes(name));
		const include = keys.filter((name) => !name.startsWith('-'));
		const exclude = keys.filter((name) => name.startsWith('-')).map((name) => name.slice(1));
		if (!include.every(isHeld) || exclude.some(isHeld)) continue;
		const searchTerms = lookup.length === 0 || lookup.includes('terms');
		const searchKanji = lookup.length === 0 || lookup.includes('kanji');
		if (include.length > 0) return { passive: false, searchTerms, searchKanji };
		passiveMatch ??= { passive: true, searchTerms, searchKanji };
	}
	return passiveMatch;
}

/** Whether any active scan input uses the right mouse button (whose context menu should then be suppressed). */
export function usesRightMouseButton(settings) {
	return [
		[settings.scanModifier, settings.scanInputs],
		[settings.popupScanModifier, settings.popupScanInputs],
	].some(([mode, inputs]) => mode === 'custom' && (inputs ?? []).some((input) => parseScanInput(input).includes('mouse1')));
}

/**
 * WebKit selects the word under the cursor on a right click. When the right button is a scan input,
 * this restores the selection from before the click, so only the scan highlight shows.
 */
export function preventRightClickSelection(doc, getSettings) {
	let savedRanges = null;
	doc.addEventListener(
		'mousedown',
		(event) => {
			if (event.button !== 2 || !usesRightMouseButton(getSettings())) return;
			const selection = doc.getSelection();
			savedRanges = selection ? Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange()) : [];
		},
		true,
	);
	doc.addEventListener(
		'contextmenu',
		(event) => {
			if (!usesRightMouseButton(getSettings())) return;
			event.preventDefault();
			const selection = doc.getSelection();
			if (selection && savedRanges !== null) {
				selection.removeAllRanges();
				for (const range of savedRanges) selection.addRange(range);
			}
			savedRanges = null;
		},
		true,
	);
}
