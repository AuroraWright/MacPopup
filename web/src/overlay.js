// The overlay page: a texthooker-ui style text box plus Yomitan-style popups, on a transparent
// page covering the whole display. The host polls the mouse and calls window.__macpopupPointer,
// and makes the window click-through everywhere except the rects reported via setHitRects.
import { mdiCog, mdiConnection, mdiDeleteSweep, mdiEyeOff, mdiPause, mdiPlay } from '@mdi/js';
import { log, nativeCall } from './lib/native.js';
import { getPopupPosition } from './lib/popup-position.js';
import { matchScanInput, preventRightClickSelection } from './lib/scan-inputs.js';
import { getTextSourceAtElementStart, getTextSourceFromPoint, searchTextSource, setHighlight } from './lib/scanner.js';
import { getSettings, loadSettings, onSettingsChanged, saveSettings } from './lib/settings.js';
import { ankiCardFormats, kanjiEntries, termEntries, tokenize } from './lib/yomitan-api.js';

const $ = (selector) => document.querySelector(selector);
const box = $('#box');
const linesElement = $('#lines');

const cjkCharacters = /[\p{scx=Hira}\p{scx=Kana}\p{scx=Han}]/imu;

function icon(path, size = 20) {
	return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="currentColor"><path d="${path}"/></svg>`;
}

function rectToArray(rect) {
	return [rect.left, rect.top, rect.width, rect.height];
}

function rectContains(rect, x, y) {
	return x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
}

// Hit rects

let hitRectsScheduled = false;

function reportHitRects() {
	if (hitRectsScheduled) return;
	hitRectsScheduled = true;
	requestAnimationFrame(() => {
		hitRectsScheduled = false;
		const rects = [];
		if (!box.hidden) rects.push(rectToArray(box.getBoundingClientRect()));
		for (const popup of popupManager.visiblePopups()) rects.push(rectToArray(popup.iframe.getBoundingClientRect()));
		nativeCall('setHitRects', { rects }).catch(() => {});
	});
}

// Toast

let toastTimer = null;

function showToast(message) {
	const toast = $('#toast');
	toast.textContent = message;
	toast.hidden = false;
	clearTimeout(toastTimer);
	toastTimer = setTimeout(() => (toast.hidden = true), 4000);
}

// Lines (same processing as texthooker-ui's App.svelte)

const state = {
	lines: [],
	lineTextCounts: new Map(),
	paused: false,
	nextId: 1,
	renderKey: '',
};

const regexCache = new Map();

function applyReplacements(text, replacements) {
	let result = text;
	for (const replacement of replacements) {
		if (replacement.enabled === false) continue;
		const key = `${replacement.pattern}||${(replacement.flags ?? []).join('')}`;
		let regex = regexCache.get(key);
		if (!regex) {
			try {
				regex = new RegExp(replacement.pattern, (replacement.flags ?? []).join(''));
			} catch (_) {
				continue;
			}
			regexCache.set(key, regex);
		}
		result = result.replace(regex, (replacement.replaces ?? '').replace(/\\t/gm, '\t').replace(/\\n/gm, '\n'));
	}
	return result;
}

function formatLineText(text, preserveWhitespace) {
	return preserveWhitespace ? text : text.replace(/\s+/g, ' ');
}

function transformLine(text) {
	const settings = getSettings();
	let line = applyReplacements(text, settings.replacements);
	if (settings.removeAllWhitespace) line = line.replace(/\s/gm, '').trim();
	if (settings.filterNonCJKLines && !line.match(cjkCharacters)) line = '';
	if (!line) return undefined;
	if (settings.preventGlobalDuplicate) {
		if ((state.lineTextCounts.get(line) ?? 0) > 0) return undefined;
	} else if (settings.preventLastDuplicate && state.lines.length) {
		if (state.lines.slice(-settings.preventLastDuplicate).some((l) => l.text === line)) return undefined;
	}
	return line;
}

function countLine(text, delta) {
	const count = (state.lineTextCounts.get(text) ?? 0) + delta;
	if (count > 0) state.lineTextCounts.set(text, count);
	else state.lineTextCounts.delete(text);
}

function isScrolledToEnd() {
	const settings = getSettings();
	const el = linesElement;
	if (settings.displayVertical) {
		return settings.reverseLineOrder ? el.scrollLeft >= -2 : Math.abs(el.scrollLeft) + el.clientWidth >= el.scrollWidth - 2;
	}
	return settings.reverseLineOrder ? el.scrollTop <= 2 : el.scrollTop + el.clientHeight >= el.scrollHeight - 2;
}

function scrollToEnd() {
	const settings = getSettings();
	const el = linesElement;
	if (settings.displayVertical) {
		el.scrollLeft = settings.reverseLineOrder ? 0 : -el.scrollWidth;
	} else {
		el.scrollTop = settings.reverseLineOrder ? 0 : el.scrollHeight;
	}
}

function addLine(rawText) {
	if (state.paused || typeof rawText !== 'string') return;
	const text = transformLine(rawText);
	if (text === undefined) return;
	const settings = getSettings();
	const atEnd = isScrolledToEnd();

	const previous = state.lines[state.lines.length - 1];
	if (settings.mergeEqualLineStarts && previous && text.startsWith(previous.text)) {
		removeLine(previous);
	}

	const line = { id: `${state.nextId++}`, text, tokens: null, element: null };
	state.lines.push(line);
	countLine(text, 1);
	while (settings.maxLines > 0 && state.lines.length > settings.maxLines) {
		removeLine(state.lines[0]);
	}

	line.element = createLineElement(line, settings.enableLineAnimation);
	if (settings.reverseLineOrder) linesElement.prepend(line.element);
	else linesElement.append(line.element);
	if (atEnd) scrollToEnd();
	void tokenizeLine(line);
}

function removeLine(line) {
	const index = state.lines.indexOf(line);
	if (index < 0) return;
	state.lines.splice(index, 1);
	countLine(line.text, -1);
	line.element?.remove();
}

function clearLines() {
	state.lines = [];
	state.lineTextCounts.clear();
	linesElement.textContent = '';
	popupManager.closeAll();
}

async function tokenizeLine(line) {
	const displayText = formatLineText(line.text, getSettings().preserveWhitespace);
	try {
		const result = await tokenize(displayText);
		const tokens = result?.content ?? [];
		// Only use the tokens if they cover the text exactly; otherwise keep point scanning.
		if (tokens.flat().map((segment) => segment.text).join('') !== displayText) return;
		line.tokens = tokens;
		if (!line.element?.isConnected) return;
		const element = createLineElement(line, false);
		line.element.replaceWith(element);
		line.element = element;
	} catch (e) {
		log('Tokenize failed', e);
	}
}

function createLineElement(line, animate) {
	const settings = getSettings();
	const p = document.createElement('p');
	p.dataset.lineId = line.id;
	p.className = 'my-2 cursor-default border-2 border-transparent';
	const vertical = settings.displayVertical;
	p.classList.add(vertical ? 'py-2' : 'px-2');
	if (vertical) {
		p.style.paddingLeft = `${settings.linePadding}rem`;
		p.style.paddingRight = `${settings.linePadding}rem`;
	} else {
		p.style.paddingTop = `${settings.linePadding}rem`;
		p.style.paddingBottom = `${settings.linePadding}rem`;
	}
	if (settings.preserveWhitespace) p.classList.add('whitespace-pre-wrap');
	if (settings.showLinePoints) p.classList.add('show-bullet');
	if (animate) p.classList.add(vertical ? 'line-enter-vertical' : 'line-enter');

	if (line.tokens) {
		let offset = 0;
		for (const segments of line.tokens) {
			const span = document.createElement('span');
			span.className = 'token';
			span.dataset.start = `${offset}`;
			if (segments[0]?.headwords) span.classList.add('token-word');
			for (const { text, reading } of segments) {
				if (settings.showFurigana && reading) {
					const ruby = document.createElement('ruby');
					ruby.append(text);
					const rt = document.createElement('rt');
					rt.textContent = reading;
					ruby.append(rt);
					span.append(ruby);
				} else {
					span.append(text);
				}
				offset += text.length;
			}
			p.append(span);
		}
	} else {
		p.textContent = formatLineText(line.text, settings.preserveWhitespace);
	}
	return p;
}

function rerenderLines() {
	const atEnd = isScrolledToEnd();
	const settings = getSettings();
	linesElement.textContent = '';
	const ordered = settings.reverseLineOrder ? [...state.lines].reverse() : state.lines;
	for (const line of ordered) {
		line.element = createLineElement(line, false);
		linesElement.append(line.element);
	}
	if (atEnd) scrollToEnd();
}

// WebSockets (same message format as texthooker-ui: raw text, or JSON with a `sentence` key)

class SocketConnection {
	constructor(url) {
		this.url = url;
		this.socket = null;
		this.state = -1;
		this.closeRequested = false;
		this.wasConnected = false;
		this.retryTimer = null;
		this.element = document.createElement('div');
		this.element.setAttribute('role', 'button');
		this.element.className = 'mx-1 header-button';
		this.element.addEventListener('click', () => this.toggle());
		this.render();
	}

	connect() {
		if (this.socket && this.socket.readyState < 2) return;
		clearTimeout(this.retryTimer);
		this.closeRequested = false;
		this.setState(0);
		try {
			const socket = new WebSocket(this.url);
			socket.onopen = () => {
				this.wasConnected = true;
				this.setState(1);
			};
			socket.onclose = () => this.onClose(socket);
			socket.onmessage = (event) => this.onMessage(event);
			this.socket = socket;
		} catch (_) {
			this.setState(3);
		}
	}

	disconnect() {
		this.closeRequested = true;
		clearTimeout(this.retryTimer);
		if (this.socket && this.socket.readyState < 2) this.socket.close(1000, 'User Request');
		this.setState(3);
	}

	destroy() {
		this.disconnect();
		this.element.remove();
	}

	toggle() {
		if (this.state === 1 || this.state === 0) this.disconnect();
		else this.connect();
	}

	onClose(socket) {
		if (socket !== this.socket) return;
		const settings = getSettings();
		if (!this.closeRequested && settings.showConnectionErrors && (this.wasConnected || !settings.continuousReconnect)) {
			showToast(this.wasConnected ? `Lost connection to ${this.url}` : `Unable to connect to ${this.url}`);
		}
		this.wasConnected = false;
		this.setState(3);
		if (!this.closeRequested && settings.continuousReconnect) {
			this.retryTimer = setTimeout(() => this.connect(), 1000);
		}
	}

	onMessage(event) {
		let line = event.data;
		try {
			line = JSON.parse(event.data)?.sentence || event.data;
		} catch (_) {
			// Plain text
		}
		addLine(line);
	}

	setState(value) {
		this.state = value;
		this.render();
	}

	render() {
		const el = this.element;
		el.hidden = !getSettings().showConnectionIcon;
		el.title = this.state === 1 ? `Connected with ${this.url}` : `Not connected (${this.url})`;
		if (this.state === 0) {
			el.innerHTML = '<span class="animate-ping relative inline-flex rounded-full h-3 w-3 mx-1 bg-primary"></span>';
			el.classList.remove('text-red-500', 'text-green-700');
		} else {
			el.innerHTML = icon(mdiConnection);
			el.classList.toggle('text-green-700', this.state === 1);
			el.classList.toggle('text-red-500', this.state !== 1);
		}
	}
}

const sockets = new Map();

function syncSockets() {
	const urls = getSettings().websocketUrls.filter((url) => url.trim().length > 0);
	for (const [url, socket] of sockets) {
		if (!urls.includes(url)) {
			socket.destroy();
			sockets.delete(url);
		}
	}
	const container = $('#socket-icons');
	for (const url of urls) {
		let socket = sockets.get(url);
		if (!socket) {
			socket = new SocketConnection(url);
			sockets.set(url, socket);
			socket.connect();
		}
		socket.render();
		container.append(socket.element);
	}
}

// Box geometry

function defaultBoxRect() {
	const width = Math.min(900, window.innerWidth - 40);
	const height = 170;
	return { x: Math.round((window.innerWidth - width) / 2), y: window.innerHeight - height - 80, width, height };
}

function clampBoxRect(rect) {
	const width = Math.min(Math.max(rect.width, 120), window.innerWidth);
	const height = Math.min(Math.max(rect.height, 60), window.innerHeight);
	const x = Math.min(Math.max(rect.x, 0), window.innerWidth - width);
	const y = Math.min(Math.max(rect.y, 0), window.innerHeight - height);
	return { x, y, width, height };
}

function applyBoxRect(rect) {
	const { x, y, width, height } = clampBoxRect(rect);
	Object.assign(box.style, { left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
	reportHitRects();
}

function currentBoxRect() {
	const rect = box.getBoundingClientRect();
	return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
}

function setUpDrag(handle, onMove) {
	let start = null;
	handle.addEventListener('pointerdown', (e) => {
		if (e.button !== 0) return;
		e.preventDefault();
		handle.setPointerCapture(e.pointerId);
		start = { x: e.screenX, y: e.screenY, rect: currentBoxRect() };
		box.classList.add('dragging');
		popupManager.closeAll();
	});
	handle.addEventListener('pointermove', (e) => {
		if (start === null) return;
		applyBoxRect(onMove(start.rect, e.screenX - start.x, e.screenY - start.y));
	});
	const end = (e) => {
		if (start === null) return;
		start = null;
		handle.releasePointerCapture(e.pointerId);
		box.classList.remove('dragging');
		void saveSettings({ boxRect: clampBoxRect(currentBoxRect()) });
	};
	handle.addEventListener('pointerup', end);
	handle.addEventListener('pointercancel', end);
}

// Popups

function computeSiteTheme() {
	const color = getComputedStyle($('#box-background')).backgroundColor;
	const [r, g, b] = (color.match(/[\d.]+/g) ?? ['255', '255', '255']).map(Number);
	return r < 128 && g < 128 && b < 128 ? 'dark' : 'light';
}

function resolveTheme(theme, siteTheme) {
	if (theme === 'site') return siteTheme;
	if (theme === 'browser') return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
	return theme;
}

class PopupManager {
	constructor() {
		this.popups = [];
		this.cardFormats = null;
		this.cardFormatsTime = 0;
	}

	visiblePopups() {
		return this.popups.filter((popup) => popup?.visible);
	}

	isVisible(depth) {
		return this.popups[depth]?.visible === true;
	}

	async get(depth) {
		let popup = this.popups[depth];
		if (!popup) {
			const iframe = document.createElement('iframe');
			iframe.className = 'yomitan-popup';
			iframe.setAttribute('scrolling', 'no');
			iframe.style.zIndex = `${2147483000 + depth}`;
			const loaded = new Promise((resolve) => iframe.addEventListener('load', resolve, { once: true }));
			iframe.src = '/popup.html';
			$('#popups').append(iframe);
			popup = { iframe, api: null, visible: false, size: null, depth };
			popup.ready = loaded.then(async () => {
				popup.api = iframe.contentWindow.macpopupPopup;
				await popup.api.ready;
				popup.api.configure({ depth });
				this.applySettingsTo(popup);
			});
			this.popups[depth] = popup;
		}
		await popup.ready;
		return popup;
	}

	applySettings() {
		for (const popup of this.popups) {
			if (popup?.api) this.applySettingsTo(popup);
		}
		this.cardFormats = null;
	}

	applySettingsTo(popup) {
		const settings = getSettings();
		const siteTheme = computeSiteTheme();
		const data = popup.iframe.dataset;
		data.theme = resolveTheme(settings.popupTheme, siteTheme);
		data.outerTheme = resolveTheme(settings.popupOuterTheme, siteTheme);
		data.siteTheme = siteTheme;
		data.themeRaw = settings.popupTheme;
		data.outerThemeRaw = settings.popupOuterTheme;
		data.popupDisplayMode = settings.popupDisplayMode;
		popup.api.applySettings(settings, { siteTheme });
	}

	getCardFormats() {
		if (this.cardFormats === null || Date.now() - this.cardFormatsTime > 10000) {
			this.cardFormatsTime = Date.now();
			this.cardFormats = ankiCardFormats().catch((e) => {
				this.cardFormats = null;
				throw e;
			});
		}
		return this.cardFormats;
	}

	/**
	 * @param {number} depth
	 * @param {object} content
	 * @param {{left: number, top: number, right: number, bottom: number}[]} sourceRects Relative to the overlay page.
	 */
	async show(depth, content, sourceRects, verticalText = false) {
		this.closeAbove(depth);
		const popup = await this.get(depth);
		const settings = getSettings();
		const scale = settings.popupScalingFactor;
		const frameWidth = popup.size?.width ?? settings.popupWidth * scale;
		const frameHeight = popup.size?.height ?? settings.popupHeight * scale;
		// Popups stay below the menu bar.
		const menuBarHeight = await nativeCall('menuBarHeight').catch(() => 0);
		const viewport = { left: 0, top: menuBarHeight, right: window.innerWidth, bottom: window.innerHeight };
		const position = getPopupPosition(sourceRects, verticalText, viewport, { frameWidth, frameHeight, scale }, settings);

		const { iframe } = popup;
		iframe.dataset.after = `${position.after}`;
		iframe.dataset.below = `${position.below}`;
		Object.assign(iframe.style, {
			left: `${position.left}px`,
			top: `${position.top}px`,
			width: `${position.width}px`,
			height: `${position.height}px`,
		});
		popup.sourceRects = sourceRects;
		const contentPromise = popup.api.setContent(content, 'clear');
		iframe.style.visibility = 'visible';
		popup.visible = true;
		reportHitRects();
		await contentPromise;
	}

	/** Shows a nested popup for a lookup made inside the popup at `parentDepth`. */
	showFromPopup(depth, content, rects, parentDepth) {
		const parent = this.popups[parentDepth];
		if (!parent?.visible) return;
		const frameRect = parent.iframe.getBoundingClientRect();
		const dx = frameRect.left + parent.iframe.clientLeft;
		const dy = frameRect.top + parent.iframe.clientTop;
		const sourceRects = rects.map(({ left, top, right, bottom }) => ({ left: left + dx, top: top + dy, right: right + dx, bottom: bottom + dy }));
		void this.show(depth, content, sourceRects);
	}

	hide(depth) {
		const popup = this.popups[depth];
		if (!popup?.visible) return;
		popup.visible = false;
		popup.iframe.style.visibility = '';
		popup.api?.stopAudio();
		popup.api?.clearScan();
		if (depth === 0) clearMainScan();
		else this.popups[depth - 1]?.api?.clearScan();
	}

	closeAbove(depth) {
		for (let i = this.popups.length - 1; i > depth; --i) this.hide(i);
		reportHitRects();
	}

	close(depth) {
		for (let i = this.popups.length - 1; i >= depth; --i) this.hide(i);
		reportHitRects();
	}

	closeAll() {
		this.close(0);
	}

	/** Topmost visible popup at a point, with the point relative to its document. */
	hitTest(x, y) {
		for (let depth = this.popups.length - 1; depth >= 0; --depth) {
			const popup = this.popups[depth];
			if (!popup?.visible) continue;
			const rect = popup.iframe.getBoundingClientRect();
			if (rectContains(rect, x, y)) {
				return { popup, x: x - rect.left - popup.iframe.clientLeft, y: y - rect.top - popup.iframe.clientTop };
			}
		}
		return null;
	}

	getSize(depth) {
		const rect = this.popups[depth].iframe.getBoundingClientRect();
		return { width: rect.width, height: rect.height };
	}

	resize(depth, width, height) {
		const popup = this.popups[depth];
		if (!popup) return;
		popup.size = { width: Math.max(width, 100), height: Math.max(height, 60) };
		popup.iframe.style.width = `${popup.size.width}px`;
		popup.iframe.style.height = `${popup.size.height}px`;
		reportHitRects();
	}
}

const popupManager = new PopupManager();

async function getDocumentTitle() {
	try {
		return await nativeCall('frontmostApp');
	} catch (_) {
		return '';
	}
}

// API used by popup frames.
window.macpopupOverlay = {
	getCardFormats: () => popupManager.getCardFormats(),
	closePopup: (depth) => popupManager.close(depth),
	closePopupsAbove: (depth) => popupManager.closeAbove(depth),
	showPopup: (depth, content, rects, parentDepth) => popupManager.showFromPopup(depth, content, rects, parentDepth),
	getPopupSize: (depth) => popupManager.getSize(depth),
	resizePopup: (depth, width, height) => popupManager.resize(depth, width, height),
	async lookupText(text) {
		const { scanLength } = getSettings();
		const fullQuery = text.slice(0, scanLength);
		const result = await termEntries(fullQuery);
		if (result.dictionaryEntries.length > 0) {
			return { type: 'term', dictionaryEntries: result.dictionaryEntries, query: fullQuery.slice(0, result.originalTextLength), fullQuery };
		}
		const character = String.fromCodePoint(fullQuery.codePointAt(0));
		const entries = await kanjiEntries(character);
		return entries.length > 0 ? { type: 'kanji', dictionaryEntries: entries, query: character, fullQuery } : null;
	},
};

// Scanning in the text box

const scan = {
	timer: null,
	source: null,
	token: 0,
	hoveredToken: null,
	hideTimer: null,
	childHideTimer: null,
	overPopup: false,
	// Depth of the popup under the cursor, -1 when none.
	overDepth: -1,
	pending: false,
};

function setHoveredToken(token) {
	if (scan.hoveredToken === token) return;
	scan.hoveredToken?.classList.remove('token-hover');
	scan.hoveredToken = token;
	if (token && getSettings().showTokenUnderline) token.classList.add('token-hover');
}

function clearMainScan() {
	clearTimeout(scan.timer);
	scan.source = null;
	scan.token++;
	setHighlight(null);
}

function scanBox(x, y, mods) {
	const settings = getSettings();
	clearTimeout(scan.timer);
	const element = document.elementFromPoint(x, y);
	const line = element?.closest('#lines p[data-line-id]');
	const token = line ? element.closest('.token') : null;
	setHoveredToken(token);
	const input = matchScanInput(settings.scanModifier, settings.scanInputs, mods);
	if (input === null) return;
	if (!line) {
		onSearchEmpty();
		return;
	}
	// Tokenized lines are looked up from the start of the hovered token, others from the character under the cursor.
	const getSource = token ? () => getTextSourceAtElementStart(token) : () => getTextSourceFromPoint(x, y);
	if (input.passive) {
		scan.timer = setTimeout(() => void scanSource(getSource()), settings.scanDelay);
	} else {
		void scanSource(getSource());
	}
}

async function scanSource(source) {
	if (!source) {
		onSearchEmpty();
		return;
	}
	if (scan.source !== null && (popupManager.isVisible(0) || scan.pending) && scan.source.hasSameStart(source)) {
		// The word that is shown or being looked up, e.g. when coming back from the popup.
		stopHideDelayed();
		return;
	}
	scan.source = source;
	const token = ++scan.token;
	let result;
	scan.pending = true;
	try {
		const [searchResult, documentTitle] = await Promise.all([searchTextSource(source), getDocumentTitle()]);
		result = searchResult && { ...searchResult, documentTitle };
	} catch (e) {
		log('Lookup failed', e);
		showToast(`Yomitan API: ${e.message ?? e}`);
		return;
	} finally {
		if (token === scan.token) scan.pending = false;
	}
	if (token !== scan.token) return;
	if (result === null) {
		onSearchEmpty();
		return;
	}
	stopHideDelayed();
	setHighlight(source);
	const rects = [...source.getRects()].map(({ left, top, right, bottom }) => ({ left, top, right, bottom }));
	await popupManager.show(0, result, rects, getSettings().displayVertical);
}

// Popup hiding works like Yomitan's Frontend: "auto-hide results" hides the popup when a scan finds
// nothing, and "hide popup on cursor exit" hides it when the cursor leaves the popups. Moving from
// the scanned word into the popup therefore never hides it.

function hideDelayed(delay) {
	if (!popupManager.isVisible(0) || scan.hideTimer !== null) return;
	// The short minimum delay matches Yomitan's, which lets the cursor reach a popup first.
	scan.hideTimer = setTimeout(() => {
		scan.hideTimer = null;
		if (!scan.overPopup) popupManager.closeAll();
	}, 50 + delay);
}

function stopHideDelayed() {
	clearTimeout(scan.hideTimer);
	scan.hideTimer = null;
}

// Entering a popup hides its child popups, like Yomitan's Popup._onFrameMouseOver. A child that the
// cursor is over again when the delay ends stays open.
function hideChildrenDelayed(depth, delay) {
	clearTimeout(scan.childHideTimer);
	const hide = () => {
		scan.childHideTimer = null;
		if (scan.overDepth <= depth) popupManager.closeAbove(depth);
	};
	if (delay > 0) {
		scan.childHideTimer = setTimeout(hide, delay);
	} else {
		hide();
	}
}

function onSearchEmpty() {
	const settings = getSettings();
	if (settings.autoHideResults) hideDelayed(settings.hideDelay);
}

// The overlay only receives mouse events while the cursor is over the box or a popup, so WebKit never
// sees the cursor leave and :hover stays on. Hover effects use this class instead, from the polled
// cursor position.
let pointerHovered = [];

function setPointerHover(x, y) {
	const target = x === null ? null : document.elementFromPoint(x, y);
	const hovered = target ? [target.closest('.header-button'), target.closest('.show-bullet')].filter(Boolean) : [];
	for (const element of pointerHovered) {
		if (!hovered.includes(element)) element.classList.remove('pointer-hover');
	}
	for (const element of hovered) element.classList.add('pointer-hover');
	pointerHovered = hovered;
}

// `pressed` lists the held mouse buttons (see lib/scan-inputs.js).
window.__macpopupPointer = (x, y, shift, ctrl, alt, meta, pressed = []) => {
	const settings = getSettings();
	const mods = { shift, ctrl, alt, meta, pressed };
	const hit = popupManager.hitTest(x, y);
	const overBox = !box.hidden && rectContains(box.getBoundingClientRect(), x, y);
	box.classList.toggle('hovered', overBox && !hit);
	setPointerHover(overBox && !hit ? x : null, y);
	if (hit) {
		clearTimeout(scan.timer);
		setHoveredToken(null);
		hit.popup.api.onPointer(hit.x, hit.y, mods);
	} else if (overBox) {
		scanBox(x, y, mods);
	} else {
		clearTimeout(scan.timer);
		setHoveredToken(null);
		if (matchScanInput(settings.scanModifier, settings.scanInputs, mods) !== null) onSearchEmpty();
	}

	const overPopup = hit !== null;
	const overDepth = hit ? hit.popup.depth : -1;
	const enteredPopup = overDepth >= 0 && overDepth !== scan.overDepth;
	scan.overDepth = overDepth;
	if (overPopup) {
		stopHideDelayed();
	} else if (scan.overPopup && settings.hidePopupOnCursorExit) {
		hideDelayed(settings.hidePopupOnCursorExitDelay);
	}
	if (enteredPopup && settings.hidePopupOnCursorExit && popupManager.isVisible(overDepth + 1)) {
		hideChildrenDelayed(overDepth, settings.hidePopupOnCursorExitDelay);
	}
	scan.overPopup = overPopup;
};

window.__macpopupOutsideClick = () => popupManager.closeAll();

// Settings

function applySettings(settings) {
	document.documentElement.dataset.theme = settings.theme;
	box.style.setProperty('--box-opacity', `${settings.boxOpacity}`);
	linesElement.style.fontSize = `${settings.fontSize}px`;
	linesElement.style.fontFamily = settings.onlineFont !== 'Off' ? `'${settings.onlineFont}'` : '';
	linesElement.style.writingMode = settings.displayVertical ? 'vertical-rl' : 'horizontal-tb';
	$('#user-css').textContent = settings.customCSS;
	$('#popup-outer-custom-css').textContent = settings.customPopupOuterCss;
	applyBoxRect(settings.boxRect ?? defaultBoxRect());

	const renderKey = JSON.stringify([
		settings.showFurigana,
		settings.linePadding,
		settings.preserveWhitespace,
		settings.showLinePoints,
		settings.reverseLineOrder,
		settings.displayVertical,
	]);
	if (renderKey !== state.renderKey) {
		state.renderKey = renderKey;
		rerenderLines();
	}
	syncSockets();
	popupManager.applySettings();
	reportHitRects();
}

function renderPauseButton() {
	const button = $('#pause-button');
	button.innerHTML = icon(state.paused ? mdiPlay : mdiPause);
	button.title = state.paused ? 'Resume (accept new lines)' : 'Pause (ignore new lines)';
	button.classList.toggle('text-warning', state.paused);
}

async function main() {
	const settings = await loadSettings();
	onSettingsChanged(applySettings);
	// Right-button scan inputs shouldn't open the context menu or select the word.
	preventRightClickSelection(document, getSettings);

	$('#clear-button').innerHTML = icon(mdiDeleteSweep);
	$('#settings-button').innerHTML = icon(mdiCog);
	$('#hide-button').innerHTML = icon(mdiEyeOff);
	renderPauseButton();
	$('#pause-button').addEventListener('click', () => {
		state.paused = !state.paused;
		renderPauseButton();
	});
	$('#clear-button').addEventListener('click', clearLines);
	$('#settings-button').addEventListener('click', () => nativeCall('openSettings'));
	$('#hide-button').addEventListener('click', () => nativeCall('setOverlayVisible', { visible: false }));
	setUpDrag($('#drag-handle'), (rect, dx, dy) => ({ ...rect, x: rect.x + dx, y: rect.y + dy }));
	setUpDrag($('#resize-handle'), (rect, dx, dy) => ({ ...rect, width: rect.width + dx, height: rect.height + dy }));
	linesElement.addEventListener('pointerdown', () => popupManager.closeAll());
	// Scrolling by hand moves the looked-up word; scrolling to show new lines keeps the popup open.
	linesElement.addEventListener('wheel', () => popupManager.closeAll(), { passive: true });
	window.addEventListener('resize', () => applyBoxRect(getSettings().boxRect ?? defaultBoxRect()));

	box.hidden = false;
	applySettings(settings);
}

main().catch((e) => log('Overlay failed to start', e));
