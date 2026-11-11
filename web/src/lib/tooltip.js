// Tooltips for titles. WebKit doesn't show them while the overlay's app isn't active, and it never is, so these
// stand in for them, as AppKit shows WebKit's (NSToolTipPanel): 1.5 s after the pointer enters an element with a
// title, or 0.25 s when it comes from another one whose tooltip shows; at the pointer and 19 px below it; hidden by
// a press or scroll until the pointer moves to another element.

// As AppKit's, which follow the system appearance: the 11 pt system font, and as measured on screen over pages of
// several colors, the toolTip material (a tint over what's behind, blurred), its text (labelColor with vibrancy), and
// the window's edge and shadow. Above everything, menus included.
const style = `
.macpopup-tooltip {
	position: fixed;
	z-index: 2147483647;
	max-width: min(300px, calc(100% - 8px));
	box-sizing: border-box;
	padding: 3px 6px;
	background-color: rgba(226, 227, 228, 0.91);
	-webkit-backdrop-filter: blur(15px);
	backdrop-filter: blur(15px);
	box-shadow: inset 0 0 0 0.5px rgba(255, 255, 255, 0.18), 0 0 0 0.5px rgba(0, 0, 0, 0.1), 0 2px 10px rgba(0, 0, 0, 0.22);
	color: #454547;
	font: 11px/13px -apple-system, system-ui, sans-serif;
	text-align: left;
	white-space: pre-line;
	overflow-wrap: break-word;
	pointer-events: none;
}

@media (prefers-color-scheme: dark) {
	.macpopup-tooltip {
		background-color: rgba(50, 52, 54, 0.82);
		box-shadow: inset 0 0 0 0.5px rgba(255, 255, 255, 0.19), 0 0 0 0.5px rgba(0, 0, 0, 0.55), 0 2px 10px rgba(0, 0, 0, 0.22);
		color: #e9e9e9;
	}
}

.macpopup-tooltip[hidden] {
	display: none;
}
`;

export class Tooltip {
	/** @param {Document} document Its body must exist. */
	constructor(document) {
		this.document = document;
		this.node = Object.assign(document.createElement('div'), { className: 'macpopup-tooltip', hidden: true });
		document.head.append(Object.assign(document.createElement('style'), { textContent: style }));
		document.body.append(this.node);
		this.target = null;
		this.timer = null;
		this.pointer = null;
		this.dismissed = null;
		// Pointer events: drag handles prevent the mouse events that would follow.
		for (const type of ['pointerdown', 'wheel']) document.addEventListener(type, () => this.dismiss(), { capture: true, passive: true });
	}

	/** Called as the pointer moves; x is null when it's elsewhere. */
	update(x, y) {
		this.pointer = x === null ? null : { x, y };
		const target = x === null ? null : (this.document.elementFromPoint(x, y)?.closest('[title]') ?? null);
		if (target === this.target) return;
		const showing = !this.node.hidden;
		clearTimeout(this.timer);
		this.node.hidden = true;
		this.target = target;
		this.dismissed = null;
		if (!target?.title) return;
		this.timer = setTimeout(() => this.show(), showing ? 250 : 1500);
	}

	show() {
		const { node, target, pointer } = this;
		if (!target?.isConnected || !target.title || pointer === null || this.dismissed === target) return;
		node.textContent = target.title;
		node.hidden = false;
		// Above the pointer when there's no room below it; within the page.
		const { width, height } = node.getBoundingClientRect();
		const { clientWidth, clientHeight } = this.document.documentElement;
		const left = Math.max(4, Math.min(pointer.x, clientWidth - width - 4));
		const below = pointer.y + 19;
		const top = below + height <= clientHeight - 4 ? below : Math.max(4, pointer.y - height - 6);
		node.style.left = `${Math.round(left)}px`;
		node.style.top = `${Math.round(top)}px`;
	}

	dismiss() {
		clearTimeout(this.timer);
		this.node.hidden = true;
		this.dismissed = this.target;
	}
}
