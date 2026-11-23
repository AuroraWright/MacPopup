// Scan inputs (lib/scan-inputs.js): Yomitan's names and order, and which input applies to the keys and buttons held.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatScanInput, isValidInputName, matchScanInput, parseScanInput } from '../../web/src/lib/scan-inputs.js';

const nothing = { shift: false, ctrl: false, alt: false, meta: false, pressed: [] };

test('inputs are parsed from commas or spaces', () => {
	assert.deepEqual(parseScanInput('ctrl, mouse1  kanji'), ['ctrl', 'mouse1', 'kanji']);
	assert.deepEqual(parseScanInput(''), []);
	assert.deepEqual(parseScanInput(undefined), []);
});

test('only Yomitan\'s names are valid', () => {
	for (const name of ['meta', 'ctrl', 'alt', 'shift', 'mouse0', 'mouse5', '-shift', '-mouse3', 'terms', 'kanji']) {
		assert.ok(isValidInputName(name), name);
	}
	for (const name of ['mouse6', 'cmd', '-terms', 'option', '']) assert.ok(!isValidInputName(name), name);
});

test('inputs are written in Yomitan\'s order: keys, buttons, excluded ones, then what is looked up', () => {
	assert.equal(formatScanInput(['kanji', '-shift', 'mouse3', 'alt', 'meta', 'mouse0', 'alt']), 'meta alt mouse0 mouse3 -shift kanji');
});

test('a held modifier scans at once, hover waits', () => {
	assert.deepEqual(matchScanInput('shift', [], { ...nothing, shift: true }), { passive: false, searchTerms: true, searchKanji: true });
	assert.equal(matchScanInput('shift', [], nothing), null);
	assert.deepEqual(matchScanInput('none', [], nothing), { passive: true, searchTerms: true, searchKanji: true });
});

test('custom inputs: an active one wins over hover, excluded keys and lookups count', () => {
	const inputs = ['', 'alt kanji', 'mouse3 -shift'];
	assert.deepEqual(matchScanInput('custom', inputs, nothing), { passive: true, searchTerms: true, searchKanji: true });
	assert.deepEqual(matchScanInput('custom', inputs, { ...nothing, alt: true }), { passive: false, searchTerms: false, searchKanji: true });
	assert.deepEqual(matchScanInput('custom', inputs, { ...nothing, pressed: ['mouse3'] }), { passive: false, searchTerms: true, searchKanji: true });
	// Shift excludes the mouse3 input, leaving hover.
	assert.deepEqual(matchScanInput('custom', inputs, { ...nothing, shift: true, pressed: ['mouse3'] }), { passive: true, searchTerms: true, searchKanji: true });
});

test('a name Yomitan doesn\'t allow never counts as held', () => {
	assert.equal(matchScanInput('custom', ['cmd'], { ...nothing, meta: true }), null);
});
