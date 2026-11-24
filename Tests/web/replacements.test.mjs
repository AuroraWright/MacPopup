// Text replacements on each line (lib/replacements.js, texthooker-ui's format).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyReplacements, applyReplacementsMapped, patternError } from '../../web/src/lib/replacements.js';

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

test('the mapped replacements give the same text, and where it came from', () => {
	const cases = [
		['【太郎】「こんにちは」', [{ pattern: '^【.*?】', replaces: '', flags: [] }, { pattern: '[「」]', replaces: '', flags: ['g'] }]],
		['abcabc', [{ pattern: '(b)', replaces: '<$1$&>', flags: ['g'] }]],
		['ab', [{ pattern: 'x*', replaces: '-', flags: ['g'] }]],
		['a|b', [{ pattern: '\\|', replaces: '\\n', flags: [] }, { pattern: '(?<=a)\\n', replaces: ' ', flags: [] }]],
		['a😀b', [{ pattern: 'a', replaces: 'AA', flags: [] }]],
		// Matches after the start, and every kind of $ in the replacement.
		['明日も晴れるといいね', [{ pattern: '明日も', replaces: 'あしたも', flags: [] }, { pattern: 'いいね', replaces: 'いいな', flags: [] }]],
		['x-ab-cd-y', [{ pattern: '(?<first>\\w)(\\w)', replaces: '[$2$1|$<first>|$&|$`|$\'|$$|$3|$0|$12|$<none>]', flags: ['g'] }]],
		['abcdefghijkl', [{ pattern: '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)', replaces: '$11$10$1$01$011$<x>', flags: [] }]],
	];
	for (const [text, replacements] of cases) {
		const mapped = applyReplacementsMapped(text, replacements);
		assert.equal(mapped.text, applyReplacements(text, replacements));
		assert.equal(mapped.sources.length, mapped.text.length);
	}
	// Kept text comes from where it was; put-in text from where its match started.
	assert.deepEqual(applyReplacementsMapped('【太郎】こんにちは', [{ pattern: '^【.*?】', replaces: '', flags: [] }]).sources, [4, 5, 6, 7, 8]);
	assert.deepEqual(applyReplacementsMapped('abc', [{ pattern: 'b', replaces: 'XY', flags: [] }]).sources, [0, 1, 1, 2]);
	assert.deepEqual(applyReplacementsMapped('abc', []), { text: 'abc', sources: [0, 1, 2] });
});
