// Screen OCR mode: an invisible copy of the text Live Text found in another app's window, laid over
// that window so the usual scanning (caret from point, Yomitan's DOM text scanner, highlights) works
// on it. Each character is an inline-block with the size and position of its box in the window, and
// its glyph is stretched to fill that box, since Yomitan only accepts points inside the glyph.
//
// The scanner reads the text in DOM order without layout newlines, so lines of one paragraph join
// up (words can wrap between lines) and paragraphs are separated by a "\n" text node, which ends
// sentences and lookups.

const SPACE = /\s/u;
const LINE_BREAK = /[\n\v\f\r\u0085\u2028\u2029]/u;
const LETTER = /[\p{L}\p{N}]/u;
const OPENING = /^[\p{Ps}\p{Pi}]$/u;
const CLOSING = /^[\p{Pe}\p{Pf}]$/u;
const BRACKET = /^[\p{Ps}\p{Pe}\p{Pi}\p{Pf}]$/u;
// Scripts written without spaces between words.
const UNSPACED = /[\p{scx=Han}\p{scx=Hira}\p{scx=Kana}\p{scx=Thai}\p{scx=Lao}\p{scx=Khmer}\p{scx=Mymr}]/u;

/**
 * @typedef {{text: string, x: number, y: number, width: number, height: number, corrected?: boolean}} OcrChar
 * @typedef {{chars: OcrChar[], vertical: boolean, area: number, cloud: boolean, matched?: boolean, match?: number}} OcrLine
 *   `match` is how recent the WebSocket line it matched is: 0 for the latest, 1 for the one before, and so on.
 */

/**
 * Lines from the native side: chars are [text, x, y, width, height] in window points, `area` is the
 * chosen area they're in (0, the first, is the dialogue), and `cloud` is set for a line the cloud
 * engine read.
 */
export function decodeLines(lines) {
	return lines
		.map((line) => ({
			vertical: !!line.vertical,
			area: line.area ?? 0,
			cloud: !!line.cloud,
			chars: line.chars.map(([text, x, y, width, height]) => ({ text, x, y, width, height })),
		}))
		.filter((line) => line.chars.some((char) => !SPACE.test(char.text)));
}

export function lineText(line) {
	return line.chars.map((char) => char.text).join('');
}

// Matching the WebSocket line

// Punctuation Live Text reads as something that looks alike, e.g. "……" as "・・・・・": these match
// each other, and a run of them is one unit on either side, however many characters it has.
const LOOKALIKES = [
	[/^[.・·⋯]+$/u, '.'],
	[/^[-‐‑‒–—―─━ー]+$/u, '-'],
	[/^[~〜]+$/u, '~'],
];

function normalize(character) {
	const key = character.normalize('NFKC').toLowerCase();
	return LOOKALIKES.find(([pattern]) => pattern.test(key))?.[1] ?? key;
}

const isLookalike = (key) => LOOKALIKES.some(([, value]) => value === key);

/**
 * Aligns `text` (a line from the WebSocket, which is what the game is drawing) with the recognized
 * lines and replaces what was misread. The whole of `text` is aligned against any stretch of the
 * OCR text (Needleman–Wunsch with free ends on the OCR side). Matching characters (or lookalike
 * punctuation) score 2, substitutions -1, and characters missing on either side -1 (whitespace in
 * `text` is free).
 *
 * When the whole of `text` doesn't match, a part of it still can (see correctPart): games often show a
 * long line a page at a time.
 *
 * Characters already corrected with another line (`corrected`) are left as they are and aren't matched.
 *
 * @param {OcrLine[]} lines
 * @param {string} text
 * @returns {{lines: OcrLine[], quality: number, missingEnd: number, partial?: boolean}} `quality` is the
 *   share of the letters and digits of `text` that matched exactly, and `missingEnd` the characters at
 *   its end that weren't found (but for closing brackets whose opening one isn't on screen); `partial` is set when only a part of `text` matched. Without a match,
 *   the lines are returned unchanged.
 */
export function correctWithText(lines, text, minQuality = 0.6) {
	// The text's units: characters, or runs of lookalike punctuation.
	const target = [];
	const targetKeys = [];
	for (const character of text) {
		const key = normalize(character);
		if (isLookalike(key) && targetKeys.at(-1) === key) target[target.length - 1] += character;
		else {
			target.push(character);
			targetKeys.push(key);
		}
	}
	// OCR characters without whitespace, which Live Text adds and removes freely, and without those
	// corrected with another line. The rest of a run of lookalike punctuation is in `group` (their
	// indexes in the line).
	const ocr = [];
	lines.forEach((line, lineIndex) => {
		line.chars.forEach((char, charIndex) => {
			if (SPACE.test(char.text) || char.corrected) return;
			const key = normalize(char.text);
			const previous = ocr.at(-1);
			if (isLookalike(key) && previous?.key === key && previous.lineIndex === lineIndex) previous.group.push(charIndex);
			else ocr.push({ lineIndex, charIndex, char, key, group: [] });
		});
	});
	// A reading in parentheses after kanji ("声音(こわね)", as some hooks give furigana) is drawn above the word, if at
	// all, and OCR mode leaves furigana out: it's skipped for free, and left out when nothing on screen matched it.
	const reading = new Int32Array(target.length).fill(-1);
	for (let k = 1; k < target.length; k++) {
		if (!/^[(（]$/u.test(target[k]) || !/\p{scx=Han}/u.test(target[k - 1])) continue;
		let close = k + 1;
		while (close < target.length && /^[\p{scx=Hira}\p{scx=Kana}ー]$/u.test(target[close])) close++;
		if (close === k + 1 || close === target.length || !/^[)）]$/u.test(target[close])) continue;
		reading.fill(k, k, close + 1);
		k = close;
	}
	const n = target.length;
	const m = ocr.length;
	// Whether there's no room before each OCR character for missed ones: its neighbor before it on the
	// line touches it (less than half a character between them). Text inserted there would be squeezed,
	// so it costs more, and a misread character takes its place instead (in "割けない、" for
	// "割けない形になるが、", the 、 is a cut-off 形 rather than the 、 four characters later).
	const sizes = lines.map((line) => {
		const extents = line.chars.filter((char) => !SPACE.test(char.text)).map((char) => (line.vertical ? char.height : char.width)).sort((a, b) => a - b);
		return extents[Math.floor(extents.length / 2)] ?? 0;
	});
	const cramped = new Uint8Array(m + 1);
	for (let j = 1; j < m; j++) {
		const before = ocr[j - 1];
		const after = ocr[j];
		if (before.lineIndex !== after.lineIndex) continue;
		const line = lines[after.lineIndex];
		const last = line.chars[before.group.at(-1) ?? before.charIndex];
		const gap = line.vertical ? after.char.y - (last.y + last.height) : after.char.x - (last.x + last.width);
		cramped[j] = gap < sizes[after.lineIndex] * 0.5 ? 1 : 0;
	}
	const significant = target.filter((character) => !SPACE.test(character)).length;
	if (n === 0 || m === 0 || significant === 0) return { lines, quality: 0, missingEnd: significant };

	// score[i][j]: best score aligning target[0..i) with ocr[..j), any OCR prefix being free. A match
	// scores 4, a mismatch -2 (-6 for whitespace, -3 for a bracket and a letter, which an engine doesn't
	// mistake for each other: a 「 the game doesn't draw is missed rather than taking a name's last letter),
	// a missed character -2 (-5 where there's no room for it) and an extra OCR character -2.
	const width = m + 1;
	const score = new Int32Array((n + 1) * width);
	const move = new Uint8Array((n + 1) * width); // 1 diagonal, 2 target gap (insert), 3 OCR gap (delete)
	for (let i = 1; i <= n; i++) {
		const gap = SPACE.test(target[i - 1]) || reading[i - 1] >= 0 ? 0 : -2;
		score[i * width] = score[(i - 1) * width] + gap;
		move[i * width] = 2;
	}
	for (let i = 1; i <= n; i++) {
		const isSpace = SPACE.test(target[i - 1]);
		const isBracket = BRACKET.test(target[i - 1]);
		const isLetter = LETTER.test(target[i - 1]);
		for (let j = 1; j <= m; j++) {
			const unlike = (isBracket && LETTER.test(ocr[j - 1].key)) || (isLetter && BRACKET.test(ocr[j - 1].key));
			const diagonal = score[(i - 1) * width + j - 1] + (targetKeys[i - 1] === ocr[j - 1].key ? 4 : isSpace ? -6 : unlike ? -3 : -2);
			const insert = score[(i - 1) * width + j] + (isSpace || reading[i - 1] >= 0 ? 0 : cramped[j] ? -5 : -2);
			const remove = score[i * width + j - 1] - 2;
			let best = diagonal;
			let direction = 1;
			if (insert > best) {
				best = insert;
				direction = 2;
			}
			if (remove > best) {
				best = remove;
				direction = 3;
			}
			score[i * width + j] = best;
			move[i * width + j] = direction;
		}
	}
	// The alignment may end anywhere in the OCR text.
	let end = 0;
	for (let j = 1; j <= m; j++) {
		if (score[n * width + j] > score[n * width + end]) end = j;
	}

	// Trace back into operations, first to last.
	const operations = [];
	let i = n;
	let j = end;
	while (i > 0) {
		const direction = j === 0 ? 2 : move[i * width + j];
		if (direction === 1) {
			operations.push({ type: 'match', target: i - 1, ocr: j - 1 });
			i--;
			j--;
		} else if (direction === 2) {
			operations.push({ type: 'insert', target: i - 1 });
			i--;
		} else {
			operations.push({ type: 'delete', ocr: j - 1 });
			j--;
		}
	}
	operations.reverse();
	// Characters left at the end of the last line it reached, where the text goes on, are misread ones
	// of what follows (e.g. cut off by the area's edge) rather than other text: they stand for it in order.
	let next = operations.length;
	while (next > 0 && operations[next - 1].type === 'insert') next--;
	for (let j = end; end > 0 && j < m && ocr[j].lineIndex === ocr[end - 1].lineIndex; j++) {
		while (next < operations.length && SPACE.test(target[operations[next].target])) next++;
		if (next === operations.length) break;
		operations[next] = { type: 'match', target: operations[next].target, ocr: j };
		next++;
	}

	// Text before the first character on screen that would go into earlier lines isn't on screen there (e.g. a hook's
	// "RINE message from " before the sender's name, aligned with the end of the message above): it's left out rather
	// than written over their text.
	const firstExact = operations.findIndex((op) => op.type === 'match' && targetKeys[op.target] === ocr[op.ocr].key && !SPACE.test(target[op.target]));
	if (firstExact > 0) {
		const firstLine = ocr[operations[firstExact].ocr].lineIndex;
		for (let k = firstExact - 1; k >= 0; k--) {
			const op = operations[k];
			if (op.type === 'insert' || ocr[op.ocr].lineIndex === firstLine) continue;
			if (op.type === 'match') operations[k] = { type: 'insert', target: op.target };
			else operations.splice(k, 1);
		}
	}

	// Readings nothing on screen matched are left out.
	const readingsShown = new Set(operations.filter((op) => op.type === 'match' && reading[op.target] >= 0).map((op) => reading[op.target]));
	const unshownReading = (index) => reading[index] >= 0 && !readingsShown.has(reading[index]);
	for (let k = operations.length - 1; k >= 0; k--) {
		if (operations[k].type === 'insert' && unshownReading(operations[k].target)) operations.splice(k, 1);
	}

	// Text at the very start or end that isn't on screen at all (e.g. a speaker name the hook adds)
	// is left out rather than squeezed into the first or last character. A single character is more
	// likely one that wasn't recognized.
	const isOcrOp = (op) => op.type !== 'insert';
	const firstOcr = operations.findIndex(isOcrOp);
	const lastOcr = operations.length - 1 - [...operations].reverse().findIndex(isOcrOp);
	if (firstOcr < 0) return { lines, quality: 0, missingEnd: significant };
	// Characters at the end that aren't on screen (yet). A closing bracket or quote doesn't count when its
	// opening one isn't on screen either: games often don't draw the 「」 a hook adds around a line (while one
	// that drew the 「 draws the 」 too, if maybe not yet).
	const openers = new Map();
	const open = [];
	target.forEach((unit, index) => {
		if (OPENING.test(unit)) open.push(index);
		else if (CLOSING.test(unit) && open.length > 0) openers.set(index, open.pop());
	});
	const onScreen = new Set(operations.filter((op) => op.type === 'match').map((op) => op.target));
	const undrawn = (index) => openers.has(index) && !onScreen.has(openers.get(index));
	const missingEnd = operations.slice(lastOcr + 1).filter((op) => !SPACE.test(target[op.target]) && !undrawn(op.target)).length;

	// Missing text at the start doesn't count against the match, but missing text at the end does:
	// it's usually still being drawn.
	// Only a short prefix like a name, though: a few matching characters shouldn't make a whole line match.
	const leadingCount = firstOcr > 1 ? target.slice(0, operations[firstOcr - 1].target + 1).filter((character) => !SPACE.test(character)).length : 0;
	const leadingMissing = leadingCount <= 12 ? leadingCount : 0;
	const exactOps = operations.filter((op) => op.type === 'match' && targetKeys[op.target] === ocr[op.ocr].key && !SPACE.test(target[op.target]));
	// Only letters and digits count, since Live Text often misreads punctuation (and "「……え？」"
	// isn't "「……ん……」"); a line of only punctuation counts all of it.
	let quality;
	if (target.some((unit) => LETTER.test(unit))) {
		const leadingEnd = leadingMissing > 0 ? operations[firstOcr - 1].target + 1 : 0;
		const exactLetters = exactOps.filter((op) => LETTER.test(target[op.target])).length;
		const leadingLetters = target.slice(0, leadingEnd).filter((unit) => LETTER.test(unit)).length;
		const allLetters = target.filter((unit, index) => LETTER.test(unit) && !unshownReading(index)).length;
		// A missing start only passes for a name when more of the line matched after it (otherwise
		// "「……はい」" would match "いいえ" on its last letter).
		const letters = exactLetters >= Math.max(3, leadingLetters) ? allLetters - leadingLetters : allLetters;
		quality = exactLetters / Math.max(1, letters);
	} else {
		quality = exactOps.length / Math.max(1, significant - leadingMissing);
	}
	if (quality < minQuality) {
		const part = correctPart(lines, ocr, target, targetKeys, operations, minQuality);
		return part ? { lines: part, quality, missingEnd, partial: true } : { lines, quality, missingEnd };
	}

	const trimmed = operations.filter((op, index) => {
		if (op.type !== 'insert') return true;
		if (index < firstOcr) return firstOcr <= 1;
		if (index > lastOcr) return operations.length - 1 - lastOcr <= 1;
		return true;
	});
	return { lines: applyOperations(lines, ocr, target, trimmed), quality, missingEnd };
}

// The fewest letters and digits a part of the text must match exactly, so a word that the text shares
// with other text (e.g. a menu item) doesn't count as the part.
const MIN_PART_LETTERS = 5;

/**
 * Corrects the lines with the part of the text they show, e.g. one page of a long line, or a line that
 * is still being drawn: what lies between the first and the last character that match exactly, if
 * enough of both the text and the recognized characters in that span matched, and the lines it's in
 * hold little else (another line that shares a phrase with the text goes on around it). Nothing outside
 * the span changes. Null when no part matches.
 */
function correctPart(lines, ocr, target, targetKeys, operations, minQuality) {
	const isExact = (op) => op.type === 'match' && targetKeys[op.target] === ocr[op.ocr].key && LETTER.test(target[op.target]);
	const first = operations.findIndex(isExact);
	if (first < 0) return null;
	const span = operations.slice(first, operations.findLastIndex(isExact) + 1);
	const exact = span.filter(isExact).length;
	const targetLetters = target.slice(span[0].target, span.at(-1).target + 1).filter((unit) => LETTER.test(unit)).length;
	const ocrLetters = ocr.slice(span[0].ocr, span.at(-1).ocr + 1).filter((entry) => LETTER.test(entry.key)).length;
	if (exact < MIN_PART_LETTERS || exact / Math.max(targetLetters, ocrLetters) < minQuality) return null;
	const [start, end] = [span[0].ocr, span.at(-1).ocr];
	const [firstLine, lastLine] = [ocr[start].lineIndex, ocr[end].lineIndex];
	const around = ocr.filter((entry, index) => (index < start || index > end) && entry.lineIndex >= firstLine && entry.lineIndex <= lastLine);
	if (around.filter((entry) => LETTER.test(entry.key)).length > 2) return null;
	return applyOperations(lines, ocr, target, span);
}

function applyOperations(lines, ocr, target, operations) {
	// What each OCR character becomes: its replacement (or nothing), plus inserted text around it.
	const edits = ocr.map(() => ({ text: null, deleted: false, before: [], after: [] }));
	let previous = -1;
	const pendingBefore = [];
	for (const op of operations) {
		if (op.type === 'insert') {
			if (previous < 0) pendingBefore.push(...target[op.target]);
			else edits[previous].after.push(...target[op.target]);
			continue;
		}
		if (op.type === 'match') edits[op.ocr].text = target[op.target];
		else edits[op.ocr].deleted = true;
		if (previous < 0) edits[op.ocr].before.push(...pendingBefore);
		previous = op.ocr;
	}
	const touched = operations.filter((op) => op.type !== 'insert').map((op) => op.ocr);
	if (touched.length === 0) return lines;
	const first = ocr[Math.min(...touched)];
	const last = ocr[Math.max(...touched)];
	const lastIndexOf = (entry) => entry.group.at(-1) ?? entry.charIndex;
	const inRegion = (lineIndex, charIndex) =>
		(lineIndex > first.lineIndex || (lineIndex === first.lineIndex && charIndex >= first.charIndex)) &&
		(lineIndex < last.lineIndex || (lineIndex === last.lineIndex && charIndex <= lastIndexOf(last)));
	const ocrIndexAt = new Map(ocr.map((entry, index) => [`${entry.lineIndex}:${entry.charIndex}`, index]));
	// The rest of each run of lookalike punctuation, which goes with its first character.
	const grouped = new Set(ocr.flatMap((entry) => entry.group.map((charIndex) => `${entry.lineIndex}:${charIndex}`)));

	// Lines with words that the match passes over without matching anything in them are other text the reading order
	// put between its rows (another column's, or a label beside them): they're left as they are. Marks without letters
	// (e.g. a ▶ at the end of a row) still go, so the rows read on as one.
	const skipped = new Set();
	for (let lineIndex = first.lineIndex + 1; lineIndex < last.lineIndex; lineIndex++) {
		const own = ocr.flatMap((entry, index) => (entry.lineIndex === lineIndex ? [{ entry, edit: edits[index] }] : []));
		if (own.filter(({ entry }) => LETTER.test(entry.key)).length < 2) continue;
		if (own.every(({ edit }) => edit.deleted && edit.before.length === 0 && edit.after.length === 0)) skipped.add(lineIndex);
	}

	return lines.map((line, lineIndex) => {
		if (lineIndex < first.lineIndex || lineIndex > last.lineIndex || skipped.has(lineIndex)) return line;
		// The recognized whitespace after each character, reused for whitespace the text has there.
		const spaceAfter = new Map();
		let lastCharIndex = -1;
		line.chars.forEach((char, charIndex) => {
			if (!SPACE.test(char.text)) lastCharIndex = charIndex;
			else if (lastCharIndex >= 0) spaceAfter.set(lastCharIndex, spaceAfter.has(lastCharIndex) ? union(spaceAfter.get(lastCharIndex), char) : char);
		});

		const chars = [];
		line.chars.forEach((char, charIndex) => {
			if (!inRegion(lineIndex, charIndex) || char.corrected) {
				chars.push(char);
				return;
			}
			// Recognized whitespace is replaced by the text's own.
			if (SPACE.test(char.text) || grouped.has(`${lineIndex}:${charIndex}`)) return;
			const entry = ocr[ocrIndexAt.get(`${lineIndex}:${charIndex}`)];
			const edit = edits[ocrIndexAt.get(`${lineIndex}:${charIndex}`)];
			// A run of lookalike punctuation takes the place of the whole run.
			const box = entry.group.reduce((box, index) => union(box, line.chars[index]), char);
			const lastIndex = lastIndexOf(entry);
			const own = edit.deleted ? [] : edit.text !== null ? [...edit.text] : [char.text, ...entry.group.map((index) => line.chars[index].text)];
			// The text's whitespace that the picture doesn't show is left out, unless it separates words (e.g.
			// "Q BACK"): line breaks (the picture's own lines show where it breaks), and other whitespace with no
			// room for it (none drawn there), rather than squeezing it into this character's box.
			const previousText = line.chars.slice(0, charIndex).findLast((other) => !SPACE.test(other.text))?.text ?? '';
			const nextText = line.chars.slice(lastIndex + 1).find((other) => !SPACE.test(other.text))?.text ?? '';
			const unshown = (list, previous, next, pattern) =>
				list.filter((character, index) => {
					if (!pattern.test(character)) return true;
					const left = list.slice(0, index).findLast((other) => !SPACE.test(other)) ?? previous;
					const right = list.slice(index + 1).find((other) => !SPACE.test(other)) ?? next;
					return separatesWords(left, right);
				});
			const after = unshown(edit.after, own.at(-1) ?? char.text, nextText[0], LINE_BREAK);
			const trailingSpaces = [];
			const isLineEnd = !line.chars.slice(lastIndex + 1).some((other) => !SPACE.test(other.text));
			if (spaceAfter.has(lastIndex)) {
				while (after.length > 0 && SPACE.test(after[after.length - 1])) trailingSpaces.unshift(after.pop());
			} else if (isLineEnd) {
				// The text's whitespace at the end of a recognized line is where it wraps (e.g. "\n　").
				while (after.length > 0 && SPACE.test(after[after.length - 1])) after.pop();
			}
			// Characters that weren't recognized often left an empty space before the next one: put
			// inserted text there instead of squeezing it into this character's box. After the last
			// character of a line, the text continues at its size, and before the first, it starts at it.
			const before = unshown(edit.before, previousText.at(-1), own[0] ?? '', LINE_BREAK);
			const isLineStart = !line.chars.slice(0, charIndex).some((other) => !SPACE.test(other.text));
			const gapFront =
				before.length > 0 && own.length > 0
					? (gapBefore(line, charIndex) ?? (isLineStart ? continuation(box, own.length, before.length, line.vertical, true) : null))
					: null;
			const gap =
				after.length > 0 && own.length > 0
					? (gapAfter(line, lastIndex) ?? (isLineEnd ? continuation(box, own.length, after.length, line.vertical) : null))
					: null;
			const parts = [
				...(gapFront ? [] : unshown(before, previousText.at(-1), own[0] ?? '', SPACE)),
				...own,
				...(gap ? [] : unshown(after, own.at(-1) ?? char.text, nextText[0], SPACE)),
			];
			if (gapFront) chars.push(...divide(gapFront, before, line.vertical));
			if (gap) chars.push(...divide(box, parts, line.vertical), ...divide(gap, after, line.vertical));
			else if (parts.length > 0) {
				chars.push(...divide(box, parts, line.vertical));
			} else if (chars.length > 0) {
				// Deleted: the character before it takes its place, so the line has no hole.
				chars[chars.length - 1] = union(chars[chars.length - 1], box);
			}
			if (trailingSpaces.length > 0) chars.push(...divide(spaceAfter.get(lastIndex), trailingSpaces, line.vertical));
		});
		// The characters in the region are new: they're the text's, and later lines leave them alone.
		const recognized = new Set(line.chars);
		return { ...line, chars: chars.map((char) => (recognized.has(char) ? char : { ...char, corrected: true })), matched: true };
	});
}

/** Whether a space between these characters separates words: letters or digits of scripts that space their words. */
function separatesWords(left, right) {
	const spaced = (character) => !!character && LETTER.test(character) && !UNSPACED.test(character);
	return spaced(left) && spaced(right);
}

/** The empty space between a character and the next one in its line, if it fits a character. */
function gapAfter(line, charIndex) {
	const char = line.chars[charIndex];
	const next = line.chars.slice(charIndex + 1).find((other) => !SPACE.test(other.text));
	if (!next) return null;
	const size = line.vertical ? char.height : char.width;
	const gap = line.vertical ? next.y - (char.y + char.height) : next.x - (char.x + char.width);
	if (gap < size * 0.6) return null;
	return line.vertical
		? { x: char.x, y: char.y + char.height, width: char.width, height: gap }
		: { x: char.x + char.width, y: char.y, width: gap, height: char.height };
}

/** The empty space between a character and the one before it in its line, if it fits a character. */
function gapBefore(line, charIndex) {
	const char = line.chars[charIndex];
	const previous = line.chars.slice(0, charIndex).findLast((other) => !SPACE.test(other.text));
	if (!previous) return null;
	const size = line.vertical ? char.height : char.width;
	const gap = line.vertical ? char.y - (previous.y + previous.height) : char.x - (previous.x + previous.width);
	if (gap < size * 0.6) return null;
	return line.vertical
		? { x: char.x, y: previous.y + previous.height, width: char.width, height: gap }
		: { x: previous.x + previous.width, y: char.y, width: gap, height: char.height };
}

/** Room for `count` more characters after `box` (or before it), which holds `own` of them, at the same size. */
function continuation(box, own, count, vertical, before = false) {
	const size = (vertical ? box.height : box.width) / own;
	return vertical
		? { x: box.x, y: before ? box.y - size * count : box.y + box.height, width: box.width, height: size * count }
		: { x: before ? box.x - size * count : box.x + box.width, y: box.y, width: size * count, height: box.height };
}

/** Splits `box` into equal parts along the line, one per string in `texts`. */
function divide(box, texts, vertical) {
	const count = texts.length;
	return texts.map((text, index) =>
		vertical
			? { text, x: box.x, y: box.y + (box.height * index) / count, width: box.width, height: box.height / count }
			: { text, x: box.x + (box.width * index) / count, y: box.y, width: box.width / count, height: box.height },
	);
}

function union(a, b) {
	const x = Math.min(a.x, b.x);
	const y = Math.min(a.y, b.y);
	return { text: a.text, x, y, width: Math.max(a.x + a.width, b.x + b.width) - x, height: Math.max(a.y + a.height, b.y + b.height) - y };
}

// Layout

function bounds(chars) {
	const x = Math.min(...chars.map((char) => char.x));
	const y = Math.min(...chars.map((char) => char.y));
	return {
		x,
		y,
		width: Math.max(...chars.map((char) => char.x + char.width)) - x,
		height: Math.max(...chars.map((char) => char.y + char.height)) - y,
	};
}

/** Whether `next` continues the paragraph of `previous` (the next line of a wrapped text). */
function continuesParagraph(previous, next) {
	if (previous.vertical !== next.vertical) return false;
	const a = bounds(previous.chars);
	const b = bounds(next.chars);
	if (previous.vertical) {
		const size = Math.max(a.width, b.width);
		if (Math.min(a.width, b.width) < size * 0.6) return false;
		const gap = a.x - (b.x + b.width);
		return gap > -size * 0.5 && gap < size * 1.2 && b.y < a.y + a.height && a.y < b.y + b.height;
	}
	const size = Math.max(a.height, b.height);
	if (Math.min(a.height, b.height) < size * 0.6) return false;
	const gap = b.y - (a.y + a.height);
	return gap > -size * 0.5 && gap < size * 1.2 && b.x < a.x + a.width && a.x < b.x + b.width;
}

/** Groups consecutive lines into paragraphs. Lines matched with the WebSocket line form one paragraph. */
export function groupParagraphs(lines) {
	const paragraphs = [];
	for (const line of lines) {
		const current = paragraphs[paragraphs.length - 1];
		const previous = current?.[current.length - 1];
		const joins = previous && (previous.matched || line.matched ? previous.matched && line.matched : continuesParagraph(previous, line));
		if (joins) current.push(line);
		else paragraphs.push([line]);
	}
	return paragraphs;
}

// Glyph box size per font size, measured once: [horizontal height, vertical width].
let glyphRatios = null;
const FONT_FAMILY = "'Hiragino Sans', 'Hiragino Kaku Gothic ProN', sans-serif";

function measureGlyphRatios(document) {
	if (glyphRatios) return glyphRatios;
	const measure = (vertical) => {
		const element = document.createElement('div');
		element.style.cssText = `position:absolute;left:0;top:0;font:100px/1 ${FONT_FAMILY};white-space:pre;visibility:hidden;${vertical ? 'writing-mode:vertical-rl;text-orientation:upright;' : ''}`;
		element.textContent = '漢';
		document.body.append(element);
		const range = document.createRange();
		range.selectNodeContents(element.firstChild);
		const rect = range.getBoundingClientRect();
		element.remove();
		return (vertical ? rect.width : rect.height) / 100 || 1;
	};
	glyphRatios = [measure(false), measure(true)];
	return glyphRatios;
}

/**
 * Fills `container` (positioned over the window, in window points) with the lines.
 * @param {HTMLElement} container
 * @param {OcrLine[]} lines
 */
// What each character's span shows: the character as read (see ocrCharOf).
const spanChars = new WeakMap();

/** The character (as decodeLines has it) a span of renderLines shows, or null. */
export function ocrCharOf(span) {
	return spanChars.get(span) ?? null;
}

export function renderLines(container, lines) {
	const document = container.ownerDocument;
	const [horizontalRatio, verticalRatio] = measureGlyphRatios(document);
	container.textContent = '';
	const spans = [];
	groupParagraphs(lines).forEach((paragraph, index) => {
		if (index > 0) container.append('\n');
		for (const line of paragraph) {
			const box = bounds(line.chars);
			const element = document.createElement('div');
			element.className = ['ocr-line', line.matched && 'ocr-matched', line.cloud && 'ocr-cloud'].filter(Boolean).join(' ');
			// For where the controller starts (see firstIndex in overlay.js).
			element.dataset.area = line.area;
			if (line.match !== undefined) element.dataset.match = line.match;
			const style = element.style;
			style.left = `${box.x}px`;
			style.top = `${box.y}px`;
			style.width = `${box.width}px`;
			style.height = `${box.height}px`;
			if (line.vertical) {
				style.writingMode = 'vertical-rl';
				style.textOrientation = 'upright';
				style.fontSize = `${box.width / verticalRatio}px`;
				style.lineHeight = `${box.width}px`;
			} else {
				style.fontSize = `${box.height / horizontalRatio}px`;
				style.lineHeight = `${box.height}px`;
			}
			let end = line.vertical ? box.y : box.x;
			for (const char of line.chars) {
				const span = document.createElement('span');
				span.className = 'ocr-char';
				span.textContent = char.text;
				spanChars.set(span, char);
				const charStyle = span.style;
				if (line.vertical) {
					charStyle.width = `${box.width}px`;
					charStyle.height = `${char.height}px`;
					charStyle.marginTop = `${char.y - end}px`;
					charStyle.left = `${char.x + char.width - (box.x + box.width)}px`;
					end = char.y + char.height;
				} else {
					charStyle.width = `${char.width}px`;
					charStyle.height = `${box.height}px`;
					charStyle.marginLeft = `${char.x - end}px`;
					charStyle.top = `${char.y - box.y}px`;
					end = char.x + char.width;
				}
				element.append(span);
				spans.push({ span, length: line.vertical ? char.height : char.width, vertical: line.vertical });
			}
			container.append(element);
		}
	});

	// Stretch each glyph along the line to the width of its box (letter-spacing counts as part of the
	// character's rect). Measured all at once so layout happens only once. The spacing goes after the
	// glyph, so where the text is shown (Highlight recognized text boxes), it's drawn shifted to the middle.
	// Measured unscaled: the container may still be scaled to the window since its last reading (the
	// rects include that), until the caller scales it for these lines.
	const transform = container.style.transform;
	container.style.transform = '';
	const range = document.createRange();
	const lengths = spans.map(({ span, vertical }) => {
		range.selectNodeContents(span.firstChild);
		const rect = range.getBoundingClientRect();
		return vertical ? rect.height : rect.width;
	});
	container.style.transform = transform;
	spans.forEach(({ span, length, vertical }, index) => {
		const spacing = length - lengths[index];
		span.style.letterSpacing = `${spacing}px`;
		span.style.setProperty(vertical ? '--center-y' : '--center-x', `${spacing / 2}px`);
	});
}
