// Screen OCR mode: an invisible copy of the text Live Text found in another app's window, laid over
// that window so the usual scanning (caret from point, Yomitan's DOM text scanner, highlights) works
// on it. Each character is an inline-block with the size and position of its box in the window, and
// its glyph is stretched to fill that box, since Yomitan only accepts points inside the glyph.
//
// The scanner reads the text in DOM order without layout newlines, so lines of one paragraph join
// up (words can wrap between lines) and paragraphs are separated by a "\n" text node, which ends
// sentences and lookups.

const SPACE = /\s/u;

/**
 * @typedef {{text: string, x: number, y: number, width: number, height: number}} OcrChar
 * @typedef {{chars: OcrChar[], vertical: boolean, matched?: boolean}} OcrLine
 */

/** Lines from the native side: chars are [text, x, y, width, height] in window points. */
export function decodeLines(lines) {
	return lines
		.map((line) => ({
			vertical: !!line.vertical,
			chars: line.chars.map(([text, x, y, width, height]) => ({ text, x, y, width, height })),
		}))
		.filter((line) => line.chars.some((char) => !SPACE.test(char.text)));
}

export function lineText(line) {
	return line.chars.map((char) => char.text).join('');
}

// Matching the WebSocket line

const normalize = (character) => character.normalize('NFKC').toLowerCase();

/**
 * Aligns `text` (a line from the WebSocket, which is what the game is drawing) with the recognized
 * lines and replaces what was misread. The whole of `text` is aligned against any stretch of the
 * OCR text (Needleman–Wunsch with free ends on the OCR side). Matching characters score 2,
 * substitutions -1, and characters missing on either side -1 (whitespace in `text` is free).
 *
 * @param {OcrLine[]} lines
 * @param {string} text
 * @returns {{lines: OcrLine[], quality: number}} `quality` is the share of `text` that matched exactly;
 *   below `minQuality` the lines are returned unchanged.
 */
export function correctWithText(lines, text, minQuality = 0.6) {
	const target = [...text];
	// OCR characters without whitespace, which Live Text adds and removes freely.
	const ocr = [];
	lines.forEach((line, lineIndex) => {
		line.chars.forEach((char, charIndex) => {
			if (!SPACE.test(char.text)) ocr.push({ lineIndex, charIndex, char, key: normalize(char.text) });
		});
	});
	const targetKeys = target.map(normalize);
	const n = target.length;
	const m = ocr.length;
	const significant = target.filter((character) => !SPACE.test(character)).length;
	if (n === 0 || m === 0 || significant === 0) return { lines, quality: 0, missingEnd: significant };

	// score[i][j]: best score aligning target[0..i) with ocr[..j), any OCR prefix being free.
	const width = m + 1;
	const score = new Int32Array((n + 1) * width);
	const move = new Uint8Array((n + 1) * width); // 1 diagonal, 2 target gap (insert), 3 OCR gap (delete)
	for (let i = 1; i <= n; i++) {
		const gap = SPACE.test(target[i - 1]) ? 0 : -1;
		score[i * width] = score[(i - 1) * width] + gap;
		move[i * width] = 2;
	}
	for (let i = 1; i <= n; i++) {
		const isSpace = SPACE.test(target[i - 1]);
		const insertCost = isSpace ? 0 : -1;
		for (let j = 1; j <= m; j++) {
			const diagonal = score[(i - 1) * width + j - 1] + (targetKeys[i - 1] === ocr[j - 1].key ? 2 : isSpace ? -3 : -1);
			const insert = score[(i - 1) * width + j] + insertCost;
			const remove = score[i * width + j - 1] - 1;
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

	// Text at the very start or end that isn't on screen at all (e.g. a speaker name the hook adds)
	// is left out rather than squeezed into the first or last character. A single character is more
	// likely one that wasn't recognized.
	const isOcrOp = (op) => op.type !== 'insert';
	const firstOcr = operations.findIndex(isOcrOp);
	const lastOcr = operations.length - 1 - [...operations].reverse().findIndex(isOcrOp);
	if (firstOcr < 0) return { lines, quality: 0, missingEnd: significant };
	// Characters at the end that aren't on screen (yet).
	const missingEnd = operations.slice(lastOcr + 1).filter((op) => !SPACE.test(target[op.target])).length;

	// Missing text at the start doesn't count against the match, but missing text at the end does:
	// it's usually still being drawn.
	// Only a short prefix like a name, though: a few matching characters shouldn't make a whole line match.
	const leadingCount = firstOcr > 1 ? target.slice(0, operations[firstOcr - 1].target + 1).filter((character) => !SPACE.test(character)).length : 0;
	const leadingMissing = leadingCount <= 12 ? leadingCount : 0;
	const exact = operations.filter((op) => op.type === 'match' && targetKeys[op.target] === ocr[op.ocr].key && !SPACE.test(target[op.target])).length;
	const quality = exact / Math.max(1, significant - leadingMissing);
	if (quality < minQuality) return { lines, quality, missingEnd };

	const trimmed = operations.filter((op, index) => {
		if (op.type !== 'insert') return true;
		if (index < firstOcr) return firstOcr <= 1;
		if (index > lastOcr) return operations.length - 1 - lastOcr <= 1;
		return true;
	});
	return { lines: applyOperations(lines, ocr, target, trimmed), quality, missingEnd };
}

function applyOperations(lines, ocr, target, operations) {
	// What each OCR character becomes: its replacement (or nothing), plus inserted text around it.
	const edits = ocr.map(() => ({ text: null, deleted: false, before: [], after: [] }));
	let previous = -1;
	const pendingBefore = [];
	for (const op of operations) {
		if (op.type === 'insert') {
			if (previous < 0) pendingBefore.push(target[op.target]);
			else edits[previous].after.push(target[op.target]);
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
	const inRegion = (lineIndex, charIndex) =>
		(lineIndex > first.lineIndex || (lineIndex === first.lineIndex && charIndex >= first.charIndex)) &&
		(lineIndex < last.lineIndex || (lineIndex === last.lineIndex && charIndex <= last.charIndex));
	const ocrIndexAt = new Map(ocr.map((entry, index) => [`${entry.lineIndex}:${entry.charIndex}`, index]));

	return lines.map((line, lineIndex) => {
		if (lineIndex < first.lineIndex || lineIndex > last.lineIndex) return line;
		// The recognized whitespace after each character, reused for whitespace the text has there.
		const spaceAfter = new Map();
		let lastCharIndex = -1;
		line.chars.forEach((char, charIndex) => {
			if (!SPACE.test(char.text)) lastCharIndex = charIndex;
			else if (lastCharIndex >= 0) spaceAfter.set(lastCharIndex, spaceAfter.has(lastCharIndex) ? union(spaceAfter.get(lastCharIndex), char) : char);
		});

		const chars = [];
		line.chars.forEach((char, charIndex) => {
			if (!inRegion(lineIndex, charIndex)) {
				chars.push(char);
				return;
			}
			// Recognized whitespace is replaced by the text's own.
			if (SPACE.test(char.text)) return;
			const edit = edits[ocrIndexAt.get(`${lineIndex}:${charIndex}`)];
			const own = edit.deleted ? [] : [edit.text ?? char.text];
			const after = [...edit.after];
			const trailingSpaces = [];
			if (spaceAfter.has(charIndex)) {
				while (after.length > 0 && SPACE.test(after[after.length - 1])) trailingSpaces.unshift(after.pop());
			}
			// Characters that weren't recognized often left an empty space before the next one: put
			// inserted text there instead of squeezing it into this character's box.
			const gap = after.length > 0 && own.length > 0 ? gapAfter(line, charIndex) : null;
			const parts = gap ? [...edit.before, ...own] : [...edit.before, ...own, ...after];
			if (gap) chars.push(...divide(char, parts, line.vertical), ...divide(gap, after, line.vertical));
			else if (parts.length > 0) {
				chars.push(...divide(char, parts, line.vertical));
			} else if (chars.length > 0) {
				// Deleted: the character before it takes its place, so the line has no hole.
				chars[chars.length - 1] = union(chars[chars.length - 1], char);
			}
			if (trailingSpaces.length > 0) chars.push(...divide(spaceAfter.get(charIndex), trailingSpaces, line.vertical));
		});
		return { ...line, chars, matched: true };
	});
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
			element.className = line.matched ? 'ocr-line ocr-matched' : 'ocr-line';
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
	// character's rect). Measured all at once so layout happens only once.
	const range = document.createRange();
	const lengths = spans.map(({ span, vertical }) => {
		range.selectNodeContents(span.firstChild);
		const rect = range.getBoundingClientRect();
		return vertical ? rect.height : rect.width;
	});
	spans.forEach(({ span, length }, index) => {
		span.style.letterSpacing = `${length - lengths[index]}px`;
	});
}
