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

test('a row set in from the one before starts a paragraph, unless the rows are centred or the dialogue hangs', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	// Rows of 40 px characters, `start` cells in from the left, with the engine's box `boxStart` cells in.
	const rows = (...specs) => decodeLines(specs.map(([text, start, boxStart = start], row) => ({
		vertical: false, area: 0, x: boxStart * 40, y: row * 50, width: (start - boxStart + [...text].length) * 40, height: 40,
		chars: [...text].map((t, i) => [t, (start + i) * 40, row * 50, 40, 40]),
	})));
	const reach = { horizontal: 800, vertical: 0 };
	// A paragraph's first row, set in a character, reaching as far as the full row before (whose 。 hangs past it).
	assert.deepEqual(paragraphBreaks(rows(['一二三四五六七八九十一二三四五六七八九。', 0], ['一二三四五六七八九十一二三四五六七八九', 1]), reach), [1]);
	// Centred rows: the shorter one ends earlier too.
	assert.deepEqual(paragraphBreaks(rows(['一二三四五六七八九十一二三四五六七八九十', 0], ['一二三四五六七八九十一二三四五六七八', 1]), reach), []);
	// Dialogue set in under its opening bracket, and a row opening with a bracket (drawn in the far half of its cell).
	assert.deepEqual(paragraphBreaks(rows(['「二三四五六七八九十一二三四五六七八九十', 0], ['一二三四五六七八九十一二三四五六七八九', 1]), reach), []);
	assert.deepEqual(paragraphBreaks(rows(['一二三四五六七八九十一二三四五六七八九十', 0], ['『二三四五六七八九十一二三四五六七八九', 1]), reach), []);
	// A row whose first characters the engine found but left out: where its box starts counts.
	assert.deepEqual(paragraphBreaks(rows(['一二三四五六七八九十一二三四五六七八九十', 0], ['三四五六七八九十一二三四五六七八九十', 2, 0]), reach), []);
	// Noise read before a row's start doesn't make the next row look set in; two paragraphs of one row each, set in.
	assert.deepEqual(paragraphBreaks(rows(['一二三四五六七八九十一二三四五六七八九十', 1], ['一二三四五六七八九十一二三四五六七八九十', 1],
		['a二三四五六七八九十一二三四五六七八九十', 0], ['一二三四五六七八九十一二三四五六七八九十', 1]), reach), []);
	const full = '一二三四五六七八九十一二三四五六七八九十', setIn = '一二三四五六七八九十一二三四五六七八九';
	assert.deepEqual(paragraphBreaks(rows([full, 0], [full, 0], [full, 0], [setIn, 1], [setIn, 1]), reach), [3, 4]);
});

test('columns set wide apart with thin character boxes go on, and a row given in pieces is one row', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	// Two columns 42 px apart whose characters are 25 px apart along them, in boxes 19 px wide (Live Text's in a
	// game's vertical text): the gap between the boxes is over 1.2 of their width, not of the characters' spacing.
	const columns = decodeLines([['一二三四五六七八九十一二三四五六七八九十', 1200], ['一二三四五六七八。', 1158]].map(([text, x]) => ({
		vertical: true, area: 0, chars: [...text].map((t, i) => [t, x, 20 + i * 25, 19, 23]),
	})));
	assert.deepEqual(paragraphBreaks(columns, { horizontal: 0, vertical: 520 }), []);
	// A row the engine gave in three pieces side by side (Live Text splits some at ellipses), after a name: the pieces
	// don't end early, and the name's row still ends its paragraph.
	const pieces = decodeLines([['詩音', 0, 0], ['「そんな……', 0, 50], ['あ、ありが', 6, 50], ['とうございます」', 11, 50]].map(([text, start, y]) => ({
		vertical: false, area: 0, x: start * 40, y, width: [...text].length * 40, height: 40,
		chars: [...text].map((t, i) => [t, (start + i) * 40, y, 40, 40]),
	})));
	assert.deepEqual(paragraphBreaks(pieces, { horizontal: 800, vertical: 0 }), [1]);
});

test('rows of outlined text go on by their engine boxes, and a row with spaces elsewhere leaves Japanese rows alone', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	const row = (text, x, y, charHeight, boxHeight) => ({
		vertical: false, area: 0, x, y, width: [...text].length * 28, height: boxHeight,
		chars: [...text].map((t, i) => [t, x + i * 28, y, 28, charHeight]),
	});
	// The first row's characters fitted to too little of its outlined strokes (14 px of 32): its box and the next
	// row's are alike, so the second row still continues it.
	const outlined = decodeLines([row('「それで兄さん。あの有栖って女は結局', 672, 488, 14, 32), row('どこの誰なんですか？」', 659, 527, 36, 36)]);
	assert.deepEqual(paragraphBreaks(outlined, { horizontal: 1180, vertical: 0 }), []);
	// A speaker's name before the dialogue ends its paragraph, though a date read at the top has a space in it.
	const named = decodeLines([row('↑ ）（日', 43, 20, 21, 21), row('【凛】', 70, 442, 24, 24), row('「ありがとうっす」', 73, 481, 23, 23)]);
	assert.deepEqual(paragraphBreaks(named), [1, 2]);
});

test('digits set sideways in a vertical column go on along it', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	// Live Text's 「合計35万人を」: "35" as a horizontal row between the column's two parts, the first part's box widened
	// by a reading beside it; the next column goes on from them.
	const row = (text, vertical, [x, y, width, height]) => ({
		vertical, area: 0, x, y, width, height,
		chars: [...text].map((t, i) => vertical
			? [t, x, y + i * (height / [...text].length), width, height / [...text].length]
			: [t, x + i * (width / [...text].length), y, width / [...text].length, height]),
	});
	const rows = decodeLines([row('合計', true, [118, 116, 62, 76]), row('35', false, [138, 194, 42, 32]),
		row('万人を', true, [144, 236, 28, 98]), row('超える見込みだ', true, [84, 118, 38, 256])]);
	assert.deepEqual(paragraphBreaks(rows, { horizontal: 0, vertical: 380 }), []);
});

test('a Japanese row opening with digits or Latin letters still starts its paragraph after a short row', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	const row = (text, y) => ({ vertical: false, area: 0, x: 0, y, width: 20 * [...text].length, height: 20,
		chars: [...text].map((t, i) => [t, i * 20, y, 20, 20]) });
	for (const opening of ['3人で行ったのは駅前の店だった。', 'ＣＤを買ったのは駅前の店だった。']) {
		const rows = decodeLines([row('一二三四五六七八九十一二三四五六七八九十', 0), row('一二三四五六七八九十一二三。', 30), row(opening, 60)]);
		assert.deepEqual(paragraphBreaks(rows, { horizontal: 400, vertical: 0 }), [2], opening);
	}
});

test('a column opening with sideways digits is still a column', async () => {
	const { decodeLines, paragraphBreaks } = await import('../../web/src/lib/ocr-layer.js');
	const row = (text, vertical, [x, y, width, height]) => ({
		vertical, area: 0, x, y, width, height,
		chars: [...text].map((t, i) => vertical
			? [t, x, y + i * (height / [...text].length), width, height / [...text].length]
			: [t, x + i * (width / [...text].length), y, width / [...text].length, height]),
	});
	const rows = decodeLines([row('35', false, [138, 100, 32, 28]), row('万人を超える', true, [140, 130, 28, 168]),
		row('見込みだと発表した', true, [100, 100, 28, 252])]);
	assert.deepEqual(paragraphBreaks(rows, { horizontal: 0, vertical: 400 }), []);
});
