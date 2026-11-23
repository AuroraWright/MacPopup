// Highlights (the scanned word, the controller's place) drawn as boxes, in place of CSS highlights. WebKit paints a
// highlight on a wrapped row from the bottom of the row above it, so a word on a line's second row got a band over
// the gap above it; and since setting a highlight repaints only the text, the band only showed once something else
// repainted the line (its bullet fading as the pointer went onto the popup), and could stay after the highlight was
// cleared. It also doesn't paint highlights on text directly in a <ruby>. The boxes are the client rects of the ranges'
// text (one per text node, as a range's own rects would add the boxes of the elements it contains), as tall as the
// characters, redrawn as the text changes or is resized. Where the text scrolls, they're in the scrolled element, so
// they scroll with it: WebKit scrolls off the main thread, and boxes moved on scroll events fell up to a line behind
// the text in a trackpad's fast scrolls.

export class HighlightBoxes {
	/**
	 * @param {HTMLElement} container The element with the text.
	 * @param {HTMLElement} layer An empty element where the boxes go, absolutely positioned with its left and top set
	 *   (its CSS decides whether they're under the text). In `container` (which scrolls, and is their containing
	 *   block): the boxes scroll with the text, and the layer is put back if the container's children are cleared.
	 *   Outside it: it's kept over the container, as big as it (its CSS decides whether it clips them).
	 */
	constructor(container, layer) {
		this.container = container;
		this.layer = layer;
		this.inside = container.contains(layer);
		/** @type {Map<string, Range[]>} The ranges shown, by the boxes' class. */
		this.ranges = new Map();
		this.frame = 0;
		if (!this.inside) container.addEventListener('scroll', () => this.redrawSoon(), { passive: true });
		// Now: resize observers are called after the frame's animation callbacks, so a redraw asked for then would
		// wait a frame, with the text already moved. The layer isn't observed, so drawing doesn't call this again.
		this.resizes = new ResizeObserver(() => {
			if (this.ranges.size > 0) this.draw();
		});
		this.resizes.observe(container);
		// Not for the boxes' own changes.
		this.mutations = new MutationObserver((records) => {
			if (records.some((record) => !layer.contains(record.target))) this.redrawSoon();
		});
	}

	/** Whether `range` is in the container's text. */
	contains(range) {
		return this.container.contains(range.startContainer);
	}

	/** Shows `ranges`' text as boxes with the class `name`, in place of the ones shown with it (none: removes them). */
	set(name, ranges) {
		if (ranges.length === 0 && !this.ranges.has(name)) return;
		if (ranges.length === 0) this.ranges.delete(name);
		else this.ranges.set(name, ranges.flatMap(textRanges));
		// Text added, redrawn, restyled or scaled moves without scrolling or resizing the container. Resize observers
		// only see block and inline-block elements (such as the OCR overlay's characters, whose boxes drawn while they
		// were hidden have no size): inline ones (the text box's and the popup's spans) never report a resize.
		this.mutations.disconnect();
		this.resizes.disconnect();
		this.resizes.observe(this.container);
		if (this.ranges.size > 0) {
			this.mutations.observe(this.container, { childList: true, subtree: true, characterData: true, attributes: true });
			for (const range of [...this.ranges.values()].flat()) {
				const element = range.startContainer.parentElement;
				if (element) this.resizes.observe(element);
			}
		}
		this.draw();
	}

	redrawSoon() {
		if (this.ranges.size === 0 || this.frame !== 0) return;
		this.frame = requestAnimationFrame(() => {
			this.frame = 0;
			this.draw();
		});
	}

	draw() {
		const { container, layer } = this;
		let origin;
		if (this.inside) {
			if (!layer.isConnected) container.append(layer);
			origin = layer.getBoundingClientRect();
		} else {
			// Moved by the difference, whatever it's positioned in.
			origin = container.getBoundingClientRect();
			const at = layer.getBoundingClientRect();
			Object.assign(layer.style, {
				left: `${(parseFloat(layer.style.left) || 0) + origin.left - at.left}px`,
				top: `${(parseFloat(layer.style.top) || 0) + origin.top - at.top}px`,
				width: `${origin.width}px`,
				height: `${origin.height}px`,
			});
		}
		const boxes = [];
		for (const [name, ranges] of this.ranges) {
			for (const range of ranges) {
				// For a bar on the line's side (the controller's), as an underline would be.
				const vertical = isVertical(range.startContainer.parentElement);
				for (const rect of range.getClientRects()) {
					if (rect.width === 0 || rect.height === 0) continue;
					const box = document.createElement('div');
					box.className = vertical ? `${name} vertical` : name;
					box.style.cssText = `left: ${rect.left - origin.left}px; top: ${rect.top - origin.top}px; width: ${rect.width}px; height: ${rect.height}px`;
					boxes.push(box);
				}
			}
		}
		layer.replaceChildren(...boxes);
	}
}

/** Shows `ranges` as boxes with the class `name` in whichever of `all` has their text (none: removes them). */
export function showHighlight(all, name, ranges) {
	for (const boxes of all) boxes.set(name, ranges.filter((range) => boxes.contains(range)));
}

/** The text of `range` as one range per text node, without the furigana (only the text under it is matched). */
function textRanges(range) {
	const root = range.commonAncestorContainer;
	if (root.nodeType === Node.TEXT_NODE) return [range.cloneRange()];
	const ranges = [];
	const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
		acceptNode: (node) => (node.parentElement?.closest('rt, rp') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
	});
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		if (!range.intersectsNode(node)) continue;
		const part = document.createRange();
		part.setStart(node, node === range.startContainer ? range.startOffset : 0);
		part.setEnd(node, node === range.endContainer ? range.endOffset : node.length);
		if (!part.collapsed) ranges.push(part);
	}
	return ranges;
}

const isVertical = (element) => !!element && getComputedStyle(element).writingMode.startsWith('vertical');
