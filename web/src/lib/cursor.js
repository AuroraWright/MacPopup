// The overlay never becomes key, so WebKit doesn't set the cursor from CSS. The cursor a browser would
// show at a point is worked out here instead, and the app sets it (see OverlayController.setCursor).

/** The CSS cursor for a point of `doc`, with `auto` resolved as a browser would: a hand over links,
 * an I-beam over selectable text and an arrow elsewhere. */
export function cursorAt(doc, x, y) {
	const element = doc.elementFromPoint(x, y);
	if (!element) return 'default';
	const style = doc.defaultView.getComputedStyle(element);
	if (style.cursor !== 'auto') return style.cursor;
	if (element.closest('a[href]')) return 'pointer';
	if (style.userSelect === 'none' || style.webkitUserSelect === 'none') return 'default';
	if (overText(doc, x, y)) return style.writingMode.startsWith('vertical') ? 'vertical-text' : 'text';
	return 'default';
}

function overText(doc, x, y) {
	const range = doc.caretRangeFromPoint(x, y);
	const node = range?.startContainer;
	if (!node || node.nodeType !== Node.TEXT_NODE) return false;
	const charRange = doc.createRange();
	for (const offset of [range.startOffset, range.startOffset - 1]) {
		if (offset < 0 || offset >= node.length) continue;
		charRange.setStart(node, offset);
		charRange.setEnd(node, offset + 1);
		for (const rect of charRange.getClientRects()) {
			if (x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom) return true;
		}
	}
	return false;
}
