// OCR lines corrected with a WebSocket line's text (lib/ocr-layer.js correctWithText): spaces in the text take a
// cell only where the screen has a gap for them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { correctWithText } from '../../web/src/lib/ocr-layer.js';

/** One recognized horizontal line in 40 px cells, with a cell-wide gap before character `gapAt`. */
function line(text, gapAt = -1) {
	return {
		vertical: false,
		chars: [...text].map((t, i) => ({ text: t, x: i * 40 + (gapAt >= 0 && i >= gapAt ? 40 : 0), y: 0, width: 40, height: 40 })),
	};
}

/** The corrected line's characters as "text@x". */
function cells(ocr, text) {
	const result = correctWithText([ocr], text);
	assert.equal(result.quality, 1);
	assert.equal(result.missingEnd, 0);
	return result.lines[0].chars.map((c) => `${c.text}@${Math.round(c.x)}`);
}

const plain = ['こ@0', 'ん@40', 'に@80', 'ち@120', 'は@160', '世@200', '界@240'];

test('the same text keeps the cells', () => {
	assert.deepEqual(cells(line('こんにちは世界'), 'こんにちは世界'), plain);
});

test('spaces with no gap on screen are left out', () => {
	for (const text of ['こんにちは 世界', 'こんにちは  世界', 'こんにちは　世界', '  こんにちは世界  ']) {
		assert.deepEqual(cells(line('こんにちは世界'), text), plain, JSON.stringify(text));
	}
});

test('a space takes the gap on screen', () => {
	assert.deepEqual(cells(line('こんにちは世界', 5), 'こんにちは 世界'),
		['こ@0', 'ん@40', 'に@80', 'ち@120', 'は@160', ' @200', '世@240', '界@280']);
});

test('replacements on rows keep each character with the box it came from, and the rows', async () => {
	const { replaceInLines, lineText } = await import('../../web/src/lib/ocr-layer.js');
	const rows = [line('【太郎】こんに'), line('ちは「世界」')];
	rows[1].chars.forEach((char) => (char.y = 50));
	const replaced = replaceInLines(rows, [{ pattern: '^【.*?】', replaces: '', flags: [] }, { pattern: '[「」]', replaces: '', flags: ['g'] }, { pattern: 'に', replaces: 'にー', flags: [] }]);
	assert.equal(replaced.text, 'こんにーちは世界');
	assert.deepEqual(replaced.lines.map(lineText), ['こんにー', 'ちは世界']);
	assert.deepEqual(replaced.lines[0].chars.map((c) => c.x), [160, 200, 240, 240]);
	assert.equal(replaced.lines[0].chars[3].source, rows[0].chars[6]);
	assert.deepEqual(replaced.lines[1].chars.map((c) => `${c.text}@${c.x},${c.y}`), ['ち@0,50', 'は@40,50', '世@120,50', '界@160,50']);
	// Nothing changed: the rows as they are.
	assert.equal(replaceInLines(rows, []).lines, rows);
	// Spaced text: what's put in where rows join is in the row before.
	const spaced = replaceInLines([line('say hi'), line('to me')], [{ pattern: '(?<=hi) ', replaces: ' - ', flags: [] }]);
	assert.equal(spaced.text, 'say hi - to me');
	assert.deepEqual(spaced.lines.map(lineText), ['say hi - ', 'to me']);
});

test('turned rows go by their paragraphs, upright ones by their boxes', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	// Two rows set at 15° (as Danganronpa's dialogue), the second starting further right: their upright boxes don't
	// overlap along the row, so as upright rows the second would start a paragraph.
	const turn = { angle: 0.26, box: [0, 0, 400, 60] };
	const rows = decodeLines([
		{ vertical: false, area: 0, paragraph: 0, turn, chars: [['鋭', 0, 0, 200, 160], ['利', 200, 0, 200, 160]] },
		{ vertical: false, area: 0, paragraph: 0, turn, chars: [['よ', 420, 170, 200, 160], ['る', 620, 170, 200, 160]] },
		{ vertical: false, area: 0, paragraph: 1, turn, chars: [['は', 0, 400, 200, 160], ['い', 200, 400, 200, 160]] },
	]);
	assert.deepEqual(rows[0].turn, { angle: 0.26, box: { x: 0, y: 0, width: 400, height: 60 } });
	assert.deepEqual(paragraphBreaks(rows, { horizontal: 820, vertical: 0 }), [2]);
	// Upright rows (no turn) are as before, whatever paragraphs the native side sent.
	const upright = decodeLines([
		{ vertical: false, area: 0, paragraph: 0, chars: [['一', 0, 0, 40, 40], ['行', 40, 0, 40, 40]] },
		{ vertical: false, area: 0, paragraph: 0, chars: [['二', 0, 300, 40, 40], ['行', 40, 300, 40, 40]] },
	]);
	assert.equal(upright[0].turn, undefined);
	assert.deepEqual(paragraphBreaks(upright, { horizontal: 80, vertical: 0 }), [1]);
});
