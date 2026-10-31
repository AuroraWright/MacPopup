// Scan inputs: which keys and mouse buttons must be held for scanning. The simple modes are a
// single modifier; 'custom' uses a list of inputs like Yomitan's scanning inputs, where each input
// is a space separated combination such as "meta", "mouse3" or "ctrl mouse1" ("" scans on hover).
//
// The names are the ones Yomitan allows in scan inputs: the modifier keys meta, ctrl, alt and shift,
// and mouse buttons by their bit in MouseEvent.buttons: mouse0 (left), mouse1 (right), mouse2
// (middle), mouse3 (back), mouse4 (forward) and mouse5.

// Yomitan's sort order (HotkeyUtil.sortModifiers).
export const modifierNames = ['meta', 'ctrl', 'alt', 'shift'];

export function isMouseButton(name) {
	return /^mouse[0-5]$/.test(name);
}

export function isValidInputName(name) {
	return modifierNames.includes(name) || isMouseButton(name);
}

/** Input names for a MouseEvent.buttons bitmask. */
export function mouseButtonNames(buttons) {
	return [0, 1, 2, 3, 4, 5].filter((bit) => (buttons & (1 << bit)) !== 0).map((bit) => `mouse${bit}`);
}

/** "ctrl, mouse1" → ['ctrl', 'mouse1'] */
export function parseScanInput(input) {
	return `${input ?? ''}`.split(/[,\s]+/).filter(Boolean);
}

/** Canonical text for a set of names, ordered like Yomitan: modifier keys, then mouse buttons. */
export function formatScanInput(names) {
	const rank = (name) => (isMouseButton(name) ? 10 + Number(name.slice(5)) : modifierNames.indexOf(name));
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
 * @returns {?{passive: boolean}} null when no input applies.
 */
export function matchScanInput(mode, customInputs, state) {
	// Names Yomitan doesn't allow never count as held, so such an entry never triggers.
	const isHeld = (name) => (modifierNames.includes(name) ? !!state[name] : isMouseButton(name) && (state.pressed ?? []).includes(name));
	const inputs = mode === 'custom' ? (customInputs ?? []).map(parseScanInput) : [mode === 'none' ? [] : [mode]];
	let passiveMatch = false;
	for (const names of inputs) {
		if (!names.every(isHeld)) continue;
		if (names.length > 0) return { passive: false };
		passiveMatch = true;
	}
	return passiveMatch ? { passive: true } : null;
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
