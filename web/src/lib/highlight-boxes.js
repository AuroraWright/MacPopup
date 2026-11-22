// Highlights (the scanned word, the controller's place) drawn as boxes, in place of CSS highlights. WebKit paints a
// highlight on a wrapped row from the bottom of the row above it, so a word on a line's second row got a band over
// the gap above it; and since setting a highlight repaints only the text, the band only showed once something else
// repainted the line (its bullet fading as the pointer went onto the popup), and could stay after the highlight was
// cleared. It also doesn't paint highlights on text directly in a <ruby>. The boxes are the ranges' client rects, as
// tall as the characters, redrawn as the text scrolls, changes or is resized.

export class HighlightBoxes {
	/**
	 * @param {HTMLElement} container The element with the text.
	 * @param {HTMLElement} layer An empty element outside `container` where the boxes go, absolutely positioned with
	 *   its left and top set: it's kept over the container (its CSS decides whether it clips them, and whether they're
	 *   under the text).
	 */
	constructor(container, layer) {
		this.container = container;
		this.layer = layer;
		/** @type {Map<string, Range[]>} The ranges shown, by the boxes' class. */
		this.ranges = new Map();
		this.frame = 0;
		const redraw = () => this.redrawSoon();
		container.addEventListener('scroll', redraw, { passive: true });
		this.resizes = new ResizeObserver(redraw);
		this.resizes.observe(container);
		this.mutations = new MutationObserver(redraw);
	}

	/** Whether `range` is in the container's text. */
	contains(range) {
		return this.container.contains(range.startContainer);
	}

	/** Shows `ranges` as boxes with the class `name`, in place of the ones shown with it (none: removes them). */
	set(name, ranges) {
		if (ranges.length === 0 && !this.ranges.has(name)) return;
		if (ranges.length === 0) this.ranges.delete(name);
		else this.ranges.set(name, ranges);
		// Text added, redrawn, restyled or scaled moves without scrolling or resizing the container; the text's own
		// elements are resized when it's shown (the boxes drawn while it was hidden have no size) or its font changes.
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
		// Moved by the difference, whatever it's positioned in.
		const area = container.getBoundingClientRect();
		const at = layer.getBoundingClientRect();
		Object.assign(layer.style, {
			left: `${(parseFloat(layer.style.left) || 0) + area.left - at.left}px`,
			top: `${(parseFloat(layer.style.top) || 0) + area.top - at.top}px`,
			width: `${area.width}px`,
			height: `${area.height}px`,
		});
		const boxes = [];
		for (const [name, ranges] of this.ranges) {
			for (const range of ranges) {
				for (const rect of range.getClientRects()) {
					if (rect.width === 0 || rect.height === 0) continue;
					const box = document.createElement('div');
					box.className = name;
					box.style.cssText = `left: ${rect.left - area.left}px; top: ${rect.top - area.top}px; width: ${rect.width}px; height: ${rect.height}px`;
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
