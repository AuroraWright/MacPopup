// Text replacements on each line (lib/replacements.js, texthooker-ui's format).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyReplacements, patternError } from '../../web/src/lib/replacements.js';

test('replacements apply in order, skipping disabled ones', () => {
	const replacements = [
		{ pattern: '「(.*)」', replaces: '$1', flags: [], enabled: true },
		{ pattern: 'a', replaces: 'b', flags: ['g'], enabled: false },
		{ pattern: '\\s+', replaces: ' ', flags: ['g'] },
	];
	assert.equal(applyReplacements('「a  a\ta」', replacements), 'a a a');
});

test('\\n and \\t in the replacement stand for a newline and a tab', () => {
	assert.equal(applyReplacements('a|b|c', [{ pattern: '\\|', replaces: '\\n', flags: ['g'] }]), 'a\nb\nc');
	assert.equal(applyReplacements('a|b', [{ pattern: '\\|', replaces: '\\t', flags: [] }]), 'a\tb');
});

test('an invalid pattern is skipped, and says why', () => {
	assert.equal(applyReplacements('abc', [{ pattern: '(', replaces: 'x', flags: [] }, { pattern: 'b', replaces: 'x', flags: [] }]), 'axc');
	assert.notEqual(patternError('(', []), '');
	assert.equal(patternError('a+', ['g']), '');
});

test('no replacements leave the text', () => {
	assert.equal(applyReplacements('abc', undefined), 'abc');
	assert.equal(applyReplacements('abc', []), 'abc');
});
