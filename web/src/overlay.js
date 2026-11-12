// The overlay page: a texthooker-ui style text box plus Yomitan-style popups, on a transparent
// page covering the whole display. The host polls the mouse and calls window.__macpopupPointer,
// and makes the window click-through everywhere except the rects reported via setHitRects.
import { mdiClipboardOffOutline, mdiClipboardTextOutline, mdiCog, mdiConnection, mdiDeleteSweep, mdiEyeOff, mdiPause, mdiPlay } from '@mdi/js';
import { log, nativeCall } from './lib/native.js';
import { getPopupPosition } from './lib/popup-position.js';
import { matchScanInput, preventRightClickSelection } from './lib/scan-inputs.js';
import { getTextSourceFromPoint, searchTextSource, setHighlight, textSourceAt } from './lib/scanner.js';
import { correctWithText, decodeLines, lineText, ocrCharOf, renderLines } from './lib/ocr-layer.js';
import { applyReplacements } from './lib/replacements.js';
import { cursorAt } from './lib/cursor.js';
import { Tooltip } from './lib/tooltip.js';
import { getSettings, loadSettings, onSettingsChanged, saveSettings } from './lib/settings.js';
import { ankiCardFormats, kanjiEntries, termEntries, tokenize, YomitanAPITimeout } from './lib/yomitan-api.js';
import { convertHiraganaToKatakana, convertKatakanaToHiragana } from '../../vendor/yomitan/ext/js/language/ja/japanese.js';
import { convertToRomaji } from '../../vendor/yomitan/ext/js/language/ja/japanese-wanakana.js';

const $ = (selector) => document.querySelector(selector);
const box = $('#box');
const tooltip = new Tooltip(document);
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
	const toast = getSettings().ocrMode ? $('#ocr-toast') : $('#toast');
	toast.textContent = message;
	toast.hidden = false;
	clearTimeout(toastTimer);
	toastTimer = setTimeout(() => (toast.hidden = true), 4000);
}

// From the host, e.g. about recording sentence audio (SentenceAudio.swift).
window.__macpopupToast = showToast;

// Lines (same processing as texthooker-ui's App.svelte)

const state = {
	lines: [],
	lineTextCounts: new Map(),
	paused: false,
	nextId: 1,
	renderKey: '',
};

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

	const line = { id: `${state.nextId++}`, text, tokens: null, element: null, tokenizing: new AbortController() };
	state.lines.push(line);
	countLine(text, 1);
	while (settings.maxLines > 0 && state.lines.length > settings.maxLines) {
		removeLine(state.lines[0]);
	}

	// Not while the box is hidden in OCR mode: it would play when the box is shown again.
	line.element = createLineElement(line, settings.enableLineAnimation && !box.hidden);
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
	line.tokenizing.abort();
}

function clearLines() {
	for (const line of state.lines) line.tokenizing.abort();
	state.lines = [];
	state.lineTextCounts.clear();
	linesElement.textContent = '';
	popupManager.closeAll();
}

async function tokenizeLine(line, retry = true) {
	const displayText = formatLineText(line.text, getSettings().preserveWhitespace);
	try {
		const result = await tokenize(displayText, line.tokenizing.signal);
		const tokens = result?.content ?? [];
		// Only use the tokens if they cover the text exactly; otherwise keep point scanning.
		if (tokens.flat().map((segment) => segment.text).join('') !== displayText) return;
		line.tokens = tokens;
		if (!line.element?.isConnected) return;
		const element = createLineElement(line, false);
		line.element.replaceWith(element);
		line.element = element;
	} catch (e) {
		if (line.tokenizing.signal.aborted) return;
		// Yomitan keeps working on a request it didn't answer in time, and keeps what it found in its parse cache: once
		// more is quick.
		if (retry && e instanceof YomitanAPITimeout) return tokenizeLine(line, false);
		log('Tokenize failed', e);
	}
}

/** Furigana in the reading mode set (Yomitan's parsing.readingMode, as its QueryParser._convertReading). */
function convertReading(reading, mode) {
	switch (mode) {
		case 'hiragana':
			return convertKatakanaToHiragana(reading);
		case 'katakana':
			return convertHiraganaToKatakana(reading);
		case 'romaji':
			return convertToRomaji(reading);
		case 'none':
			return '';
		default:
			// 'dictionary-reading': as the tokenizer has it.
			return reading;
	}
}

/** Whether `text` is only punctuation, symbols and spaces. */
function isPunctuation(text) {
	return /^[\p{P}\p{S}\s]+$/u.test(text);
}

function createLineElement(line, animate) {
	const settings = getSettings();
	const p = document.createElement('p');
	p.dataset.lineId = line.id;
	p.className = 'cursor-default border-2 border-transparent';
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
	if (animate) {
		p.classList.add(vertical ? 'line-enter-vertical' : 'line-enter');
		// Otherwise it plays again whenever the box is shown again after OCR mode (hiding it cancels the animation).
		const done = () => p.classList.remove('line-enter', 'line-enter-vertical');
		p.addEventListener('animationend', done, { once: true });
		p.addEventListener('animationcancel', done, { once: true });
	}

	if (line.tokens) {
		let offset = 0;
		for (const segments of line.tokens) {
			const span = document.createElement('span');
			span.className = 'token';
			span.dataset.start = `${offset}`;
			// Yomitan's "Term spacing".
			if (settings.termSpacing) span.style.marginInlineEnd = '0.2em';
			for (const { text, reading } of segments) {
				// Not on punctuation: the tokenizer gives "。" the reading "まる", for example.
				const furigana = settings.showFurigana && reading && !isPunctuation(text) ? convertReading(reading, settings.furiganaReadingMode) : '';
				if (furigana) {
					const ruby = document.createElement('ruby');
					// In an <rb>, so the scan highlight shows on it (see wrapRubyBases).
					const rb = document.createElement('rb');
					rb.append(text);
					ruby.append(rb);
					const rt = document.createElement('rt');
					rt.textContent = furigana;
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

// WebSockets (same message format as texthooker-ui: raw text, or JSON with a `sentence` key). A video player's
// lines (iina-plugin/) also have a `player` key, with their timing and file.

class SocketConnection {
	constructor(url) {
		this.url = url;
		this.socket = null;
		this.state = -1;
		this.closeRequested = false;
		this.wasConnected = false;
		this.retryTimer = null;
		// Reconnecting by itself after the connection closed: the icon stays as it is meanwhile rather than flash
		// between connecting and not connected at each try.
		this.retrying = false;
		this.element = document.createElement('div');
		this.element.setAttribute('role', 'button');
		this.element.className = 'mx-1 header-button';
		this.element.addEventListener('click', () => this.toggle());
		this.render();
	}

	connect(retrying = false) {
		if (this.socket && this.socket.readyState < 2) return;
		clearTimeout(this.retryTimer);
		this.retryTimer = null;
		this.closeRequested = false;
		this.retrying = retrying;
		this.setState(0);
		try {
			const socket = new WebSocket(this.url);
			socket.binaryType = 'arraybuffer';
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
		const reconnects = alwaysReconnects(settings) || settings.continuousReconnect;
		if (!this.closeRequested && settings.showConnectionErrors && (this.wasConnected || !reconnects)) {
			showToast(this.wasConnected ? `Lost connection to ${this.url}` : `Unable to connect to ${this.url}`);
		}
		this.wasConnected = false;
		this.setState(3);
		if (!this.closeRequested && reconnects) {
			this.retryTimer = setTimeout(() => this.connect(true), 1000);
		}
	}

	onMessage(event) {
		// IINA's plugin WebSocket server sends text as binary messages.
		const data = typeof event.data === 'string' ? event.data : new TextDecoder().decode(event.data);
		let line = data;
		let message = null;
		try {
			message = JSON.parse(data);
			line = message?.sentence || data;
		} catch (_) {
			// Plain text
		}
		addLine(line);
		ocrWebsocketLine(line);
		// The socket too: the line's video or audio may have to be asked of the player on it (MediaClip.swift).
		if (message?.player) addPlayerLine(line, { ...message.player, socket: this.url });
	}

	setState(value) {
		this.state = value;
		this.render();
		updateOcrWebsocket();
		reportConnectedSockets();
	}

	render() {
		const el = this.element;
		let address = this.url;
		try {
			address = new URL(this.url).host;
		} catch (_) {
			// Shown as given
		}
		el.title = `WebSocket ${address}`;
		if (this.state === 0 && !this.retrying) {
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

// Recent lines from a video player, the newest first, with the player's part of the message (the line's id, timing,
// and where its video and audio are read from) and the WebSocket it came on.
const playerLines = [];

const withoutWhitespace = (text) => text.replace(/\s/g, '');

function addPlayerLine(rawText, player) {
	if (typeof rawText !== 'string' || typeof player.line !== 'string') return;
	const text = withoutWhitespace(applyReplacements(rawText, getSettings().replacements));
	if (!text) return;
	playerLines.unshift({ text, player });
	playerLines.length = Math.min(playerLines.length, 100);
}

/**
 * The video player's line that a sentence was scanned in (in the text box, or matched with OCR Mode's text),
 * or null.
 */
function findPlayerLine(sentence) {
	const text = withoutWhitespace(sentence ?? '');
	if (!text) return null;
	return playerLines.find((line) => line.text.includes(text) || text.includes(line.text))?.player ?? null;
}

/**
 * In OCR mode with WebSocket lines, WebSockets always reconnect: the box with their icons (which
 * reconnect when clicked) isn't shown there.
 */
function alwaysReconnects(settings) {
	return !!settings.ocrMode && !!settings.ocrUseWebsocket;
}

let connectedUrls = '';

/** Shows on the menu bar icon whether a WebSocket is connected. */
function reportConnectedSockets() {
	const connected = [...sockets.values()].filter((socket) => socket.state === 1).map((socket) => socket.url);
	if (connected.join('\n') === connectedUrls) return;
	connectedUrls = connected.join('\n');
	nativeCall('websockets', { connected }).catch(() => {});
}

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
		// Not connected and not about to retry (e.g. disconnected by hand in Window Mode).
		if (alwaysReconnects(getSettings()) && socket.state === 3 && socket.retryTimer === null) socket.connect();
	}
	reportConnectedSockets();
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
		updateHotkeys();
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
		popup.api?.closeMenus();
		popup.api?.clearScan();
		popup.api?.stopRendering();
		popup.api?.setPointerHover(null, null);
		updateHotkeys();
		if (depth === 0) {
			// Hovering the word again opens it again. A scan that's scheduled or being looked up is
			// for where the cursor is now (auto-hide fires after it left the old word), so it goes on.
			if (!scan.pending) scan.source = null;
			setHighlight(null);
			applyDeferredOcr();
		} else {
			this.popups[depth - 1]?.api?.clearScan();
		}
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

// Keyboard shortcuts (Yomitan's popup hotkeys). The host registers them as global hotkeys only while a
// popup shows, since the overlay never has keyboard focus; otherwise their keys go to the app as usual.
let activeHotkeys = [];
let registeredHotkeys = null;

function updateHotkeys() {
	const visible = popupManager.visiblePopups().length > 0;
	const hotkeys = visible ? (getSettings().hotkeys ?? []).filter(({ enabled, key }) => enabled && typeof key === 'string' && key !== '') : [];
	activeHotkeys = hotkeys;
	const combinations = hotkeys.map(({ key, modifiers }) => ({ key, modifiers: Array.isArray(modifiers) ? modifiers : [] }));
	updateGamepadHold();
	const json = JSON.stringify(combinations);
	if (json === registeredHotkeys) return;
	registeredHotkeys = json;
	nativeCall('setHotkeys', { hotkeys: combinations })
		.then((results) => {
			const failed = hotkeys.filter((_, i) => results?.[i] === false);
			if (failed.length > 0) log('Keyboard shortcuts in use elsewhere:', failed.map(({ key, modifiers }) => [...modifiers, key].join('+')).join(', '));
		})
		.catch(() => {});
}

window.__macpopupUpdateHotkeys = () => {
	registeredHotkeys = null;
	updateHotkeys();
};

window.__macpopupHotkey = (index) => {
	if (activeHotkeys[index]) runHotkey(activeHotkeys[index]);
};

/** Runs a popup shortcut's action (pressed on the keyboard, or on a controller). */
function runHotkey(hotkey) {
	const argument = typeof hotkey.argument === 'string' ? hotkey.argument : '';
	if (hotkey.action === 'toggleOption') {
		const value = getSettings()[argument];
		if (typeof value === 'boolean') void saveSettings({ [argument]: !value });
		return;
	}
	// The popup on top gets it, as the focused popup would in Yomitan.
	popupManager.visiblePopups().at(-1)?.api?.runHotkey(hotkey.action, argument);
}

async function getDocumentTitle() {
	// In screen OCR mode, the app being read.
	const ocrWindow = getSettings().ocrMode && getSettings().ocrWindow;
	if (ocrWindow?.ownerName) return ocrWindow.ownerName;
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
	/** The text selected in the popup at `depth`, or in the text box for -1. */
	getSelectionText(depth) {
		const target = depth < 0 ? window : popupManager.popups[depth]?.iframe.contentWindow;
		return target?.getSelection()?.toString() ?? '';
	},
	async lookupText(text) {
		const { scanLength } = getSettings();
		const fullQuery = text.slice(0, scanLength);
		if (fullQuery.trim().length === 0) return null;
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
	hideTimer: null,
	childHideTimer: null,
	overPopup: false,
	// Depth of the popup under the cursor, -1 when none.
	overDepth: -1,
	pending: false,
};

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
	const input = matchScanInput(settings.scanModifier, settings.scanInputs, mods);
	if (input === null) return;
	if (!line) {
		onSearchEmpty();
		return;
	}
	// From the character under the cursor, as Yomitan does, also in tokenized lines: the tokenizer can join
	// words (e.g. "それでも、好き"), so the token's start isn't always where a lookup should begin.
	const getSource = () => getTextSourceFromPoint(x, y);
	if (input.passive) {
		scan.timer = setTimeout(() => void scanSource(getSource(), settings.displayVertical, input), settings.scanDelay);
	} else {
		void scanSource(getSource(), settings.displayVertical, input);
	}
}

/**
 * Looks up `source` and shows its popup. Returns whether it found something (or it's the word shown already).
 * @param {{searchTerms: boolean, searchKanji: boolean}} [lookup] What the scan input looks up.
 * @param {{quiet?: boolean, delay?: number, onFound?: () => void}} [options] Quiet: finding nothing changes nothing (the popup and its word
 *   stay), as when the controller steps over punctuation. Delay: the word is highlighted at once, and its popup shows
 *   after this many milliseconds, unless another lookup started meanwhile (it resolves without waiting).
 */
async function scanSource(source, vertical = getSettings().displayVertical, lookup = undefined, { quiet = false, delay = 0, onFound } = {}) {
	if (!source) {
		if (!quiet) onSearchEmpty();
		return false;
	}
	if (scan.source !== null && (popupManager.isVisible(0) || scan.pending) && scan.source.hasSameStart(source)) {
		// The word that is shown or being looked up, e.g. when coming back from the popup.
		stopHideDelayed();
		return true;
	}
	const previous = scan.source;
	scan.source = source;
	const token = ++scan.token;
	let result;
	scan.pending = true;
	try {
		const [searchResult, documentTitle] = await Promise.all([searchTextSource(source, lookup), getDocumentTitle()]);
		result = searchResult && { ...searchResult, documentTitle, player: findPlayerLine(searchResult.sentence?.text) };
	} catch (e) {
		log('Lookup failed', e);
		showToast(`Yomitan API: ${e.message ?? e}`);
		return false;
	} finally {
		if (token === scan.token) scan.pending = false;
	}
	if (token !== scan.token) return false;
	if (result === null) {
		if (quiet) scan.source = previous;
		else onSearchEmpty();
		return false;
	}
	stopHideDelayed();
	setHighlight(source);
	onFound?.();
	const show = () => {
		const rects = [...source.getRects()].map(({ left, top, right, bottom }) => ({ left, top, right, bottom }));
		return popupManager.show(0, result, rects, vertical);
	};
	if (delay > 0) {
		setTimeout(() => {
			if (token === scan.token) void show();
		}, delay);
	} else {
		await show();
	}
	return true;
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
	// The box's titles (its header buttons, drag and resize handles).
	tooltip.update(x, y);
}

// The cursor the app shows over the box and popups (null: whatever the app below shows).
let shownCursor = null;

function setCursor(cursor) {
	if (cursor === shownCursor) return;
	shownCursor = cursor;
	nativeCall('setCursor', { cursor }).catch(() => {});
}

// `pressed` lists the held mouse buttons (see lib/scan-inputs.js).
// Words are looked up when the cursor moves, or when a scan key or button is pressed: not when only
// something else changes under a resting cursor (e.g. a click advancing a game's text). Without
// "Scan without mouse move", as in Yomitan, only a mouse button press does without moving.
let lastPointer = null;
let lastPressed = [];
let scanKeyHeld = false;
// The popup that has the pointer hover (see Popup.setPointerHover).
let pointerPopup = null;

window.__macpopupPointer = (x, y, shift, ctrl, alt, meta, pressed = []) => {
	const moved = lastPointer === null || x !== lastPointer.x || y !== lastPointer.y;
	lastPointer = { x, y };
	const lastPressedBefore = lastPressed;
	const buttonPressed = pressed.some((button) => !lastPressed.includes(button));
	lastPressed = pressed;
	const settings = getSettings();
	const mods = { shift, ctrl, alt, meta, pressed };
	const input = matchScanInput(settings.scanModifier, settings.scanInputs, mods);
	const wasHeld = scanKeyHeld;
	scanKeyHeld = input !== null && !input.passive;
	const scansAtRest = settings.scanWithoutMousemove !== false || buttonPressed;
	const mayScan = moved || (scanKeyHeld && !wasHeld && scansAtRest);
	const hit = popupManager.hitTest(x, y);
	const overBox = !box.hidden && rectContains(box.getBoundingClientRect(), x, y);
	const ocrLine = !hit && !overBox ? ocrLineAt(x, y) : null;
	box.classList.toggle('hovered', overBox && !hit);
	setPointerHover(overBox && !hit ? x : null, y);
	if (pointerPopup !== null && pointerPopup !== hit?.popup) pointerPopup.api?.setPointerHover(null, null);
	pointerPopup = hit?.popup ?? null;
	const popupCursor = hit?.popup.api.setPointerHover(hit.x, hit.y);
	setCursor(hit ? popupCursor : overBox ? cursorAt(document, x, y) : null);
	if (hit) {
		clearTimeout(scan.timer);
		// The mouse's back and forward buttons go through the popup's history, as in Yomitan.
		if (!settings.preventBackForwardInPopups && buttonPressed) {
			if (pressed.includes('mouse3') && !lastPressedBefore.includes('mouse3')) hit.popup.api.navigate(-1);
			else if (pressed.includes('mouse4') && !lastPressedBefore.includes('mouse4')) hit.popup.api.navigate(1);
		}
		hit.popup.api.onPointer(hit.x, hit.y, mods, moved || scansAtRest);
	} else if (gamepad.focus) {
		// The controller has the text: the pointer leaves its word and popup alone.
		clearTimeout(scan.timer);
	} else if (overBox) {
		if (mayScan) scanBox(x, y, mods);
	} else if (ocrLine) {
		if (mayScan) scanOcr(x, y, mods, ocrLine);
	} else {
		clearTimeout(scan.timer);
		if (matchScanInput(settings.scanModifier, settings.scanInputs, mods) !== null) onSearchEmpty();
	}

	const overPopup = hit !== null;
	const overDepth = hit ? hit.popup.depth : -1;
	const enteredPopup = overDepth >= 0 && overDepth !== scan.overDepth;
	scan.overDepth = overDepth;
	if (overPopup) {
		stopHideDelayed();
	} else if (scan.overPopup && settings.hidePopupOnCursorExit && !gamepad.focus) {
		hideDelayed(settings.hidePopupOnCursorExitDelay);
	}
	if (enteredPopup && settings.hidePopupOnCursorExit && popupManager.isVisible(overDepth + 1)) {
		hideChildrenDelayed(overDepth, settings.hidePopupOnCursorExitDelay);
	}
	scan.overPopup = overPopup;
};

window.__macpopupOutsideClick = () => popupManager.closeAll();
// Popups close when switching spaces, in Window mode too (the box shows on every space).
window.__macpopupSpaceChanged = () => popupManager.closeAll();

// Copied text, with "Read copied text from clipboard" (see ClipboardMonitor.swift).
window.__macpopupClipboard = (text) => {
	const max = getSettings().clipboardMaxLength;
	addLine(Number.isFinite(max) && max > 0 && text.length > max ? text.slice(0, max) : text);
};

// Screen OCR mode: the host reads another app's window with Live Text (OCRController.swift) and
// sends the text here, where it's laid over the window invisibly (lib/ocr-layer.js) for scanning.

const ocr = {
	window: null,
	// Another window is in front of the target under the cursor.
	covered: false,
	// The latest WebSocket line, matched against what's read. It's kept outside OCR mode too, for the
	// readings after switching to it.
	line: null,
	// The lines before it that may still be on screen, oldest first (at most "Earlier lines on the
	// page"): games often add a line at a time to a page of them.
	earlierLines: [],
	// A new line arrived and the dialogue wasn't read since.
	awaitingLine: false,
	// The window is being read again: the text may be outdated, so it isn't scanned until the result.
	stale: false,
	// Whether the host was told that WebSocket lines are the cue to read the window.
	websocketConnected: null,
	key: null,
	size: null,
	// What replaces the text once the popups are closed ({clear: true}, or a reading's {lines, size, key}): a
	// reading with the popup's word still where it was waits, so the word's highlight stays with the popup (a
	// reading without it is shown at once). The text isn't scanned meanwhile.
	deferred: null,
};

function setOcrWindow(message) {
	const layer = $('#ocr-layer');
	const wasShown = !layer.hidden;
	ocr.window = message.visible ? message : null;
	layer.hidden = !ocr.window || !getSettings().ocrMode;
	if (layer.hidden) {
		// E.g. the window is on another space now: its popups go with its text.
		if (wasShown) popupManager.closeAll();
		clearMainScan();
		return;
	}
	Object.assign(layer.style, { left: `${message.x}px`, top: `${message.y}px`, width: `${message.width}px`, height: `${message.height}px` });
	applyOcrScale();
}

// The window was resized since it was read: scale the text with it until it's read again.
function applyOcrScale() {
	const text = $('#ocr-text');
	if (!ocr.window || !ocr.size) {
		text.style.transform = '';
		return;
	}
	const scaleX = ocr.window.width / ocr.size.width;
	const scaleY = ocr.window.height / ocr.size.height;
	text.style.transform = Math.abs(scaleX - 1) < 0.001 && Math.abs(scaleY - 1) < 0.001 ? '' : `scale(${scaleX}, ${scaleY})`;
}

function clearOcrText() {
	// The reading that follows decides whether the popup's word is still there.
	if (highlightedOcrChars()) {
		ocr.deferred = { clear: true };
		return;
	}
	ocr.deferred = null;
	ocr.stale = false;
	clearMainScan();
	$('#ocr-text').textContent = '';
}

/** Shows what was kept for when the popups closed (see ocr.deferred). */
function applyDeferredOcr() {
	const deferred = ocr.deferred;
	if (!deferred) return;
	ocr.deferred = null;
	if (deferred.clear) clearOcrText();
	else renderOcrResult(deferred);
}

/**
 * The characters of the word shown in the popup (or being looked up) in the OCR text, as read (see decodeLines), while
 * a popup is open. Null otherwise.
 */
function highlightedOcrChars() {
	const range = scan.source?.range;
	const container = $('#ocr-text');
	if (popupManager.visiblePopups().length === 0 || !range || !container.contains(range.startContainer)) return null;
	const node = range.startContainer;
	const first = (node.nodeType === Node.ELEMENT_NODE ? node.childNodes[range.startOffset] ?? node : node.parentElement)?.closest?.('.ocr-char');
	if (!first) return null;
	// From the word's first character, as many as it has text (a character's text can be longer than one).
	const length = range.toString().length;
	const spans = [...container.querySelectorAll('.ocr-char')];
	const chars = [];
	let text = '';
	for (let i = spans.indexOf(first); i >= 0 && i < spans.length && text.length < length; i++) {
		const char = ocrCharOf(spans[i]);
		if (!char) return null;
		chars.push(char);
		text += char.text;
	}
	return chars.length > 0 ? chars : null;
}

/**
 * Whether `lines` (read at `size`) have `chars` (read at ocr.size) in a row, each at about the same place: within half
 * its size of where it was.
 */
function hasCharsInPlace(lines, size, chars) {
	const scaleX = ocr.size ? ocr.size.width / size.width : 1;
	const scaleY = ocr.size ? ocr.size.height / size.height : 1;
	const center = (char, sx = 1, sy = 1) => [(char.x + char.width / 2) * sx, (char.y + char.height / 2) * sy];
	const inPlace = (old, now) => {
		if (old.text !== now.text) return false;
		const [ox, oy] = center(old);
		const [nx, ny] = center(now, scaleX, scaleY);
		return Math.hypot(nx - ox, ny - oy) <= Math.max(old.width, old.height) / 2;
	};
	return lines.some((line) => line.chars.some((_, start) => chars.every((old, i) => line.chars[start + i] && inPlace(old, line.chars[start + i]))));
}

/**
 * Corrects the rest of the dialogue with the earlier lines (see ocr.earlierLines), latest first, each in
 * the text no later line matched. They were drawn completely before the latest line, so only a whole
 * line counts, with nothing missing at its end: a few of its words in other text (e.g. a name it starts
 * with) don't.
 *
 * Lines that don't match are kept: a reading can miss one for a moment (e.g. while the game dims the
 * page's earlier lines), and the next one shows it again.
 */
function correctWithEarlierLines(lines, minQuality, debug) {
	// At most "Previous WebSocket lines to match" (the setting may have been lowered since they were kept).
	const count = Math.max(0, getSettings().ocrEarlierLines);
	ocr.earlierLines = count > 0 ? ocr.earlierLines.slice(-count) : [];
	for (const [index, line] of [...ocr.earlierLines].reverse().entries()) {
		const result = correctWithText(lines, line, minQuality);
		const used = result.quality >= minQuality && result.missingEnd === 0 && !result.partial;
		if (used) lines = markMatch(result.lines, index + 1);
		debug?.push({ line, ...matchSummary(result), used });
	}
	return lines;
}

/** Notes on lines just matched with a WebSocket line how recent it is (`match`; see OcrLine). */
function markMatch(lines, match) {
	return lines.map((line) => (line.matched && line.match === undefined ? { ...line, match } : line));
}

/** What correctWithText found, for the debug log. */
function matchSummary(result) {
	return { quality: Math.round(result.quality * 1000) / 1000, missingEnd: result.missingEnd, partial: !!result.partial };
}

/**
 * With "Highlight recognized text boxes (debug)" on, writes `record` to the OCR debug log (ocr-debug.jsonl in
 * Application Support/MacPopup; see OCRDebugLog.swift): each reading, what was done with it, and each
 * WebSocket line.
 */
function logOcrDebug(record) {
	if (!getSettings().ocrShowBoxes) return;
	nativeCall('ocrDebugLog', { json: JSON.stringify({ time: new Date().toISOString(), ...record }) }).catch(() => {});
}

function showOcrResult(message) {
	const decoded = decodeLines(message.lines);
	// Only the first area is the dialogue: the WebSocket line is matched against it. A reading of
	// only the other areas (`dialogue` false) isn't the one a new line waits for, and leaves out the
	// previous dialogue meanwhile.
	const readsDialogue = message.dialogue ?? true;
	let dialogue = !readsDialogue && ocr.awaitingLine ? [] : decoded.filter((line) => line.area === 0);
	const others = decoded.filter((line) => line.area !== 0);
	// WebSocket lines count only while one is connected: otherwise the last line is no longer news, and the
	// readings are taken as they are, as with WebSocket lines off.
	const usesLine = ocr.line !== null && !!ocr.websocketConnected;
	const minQuality = getSettings().ocrMatchThreshold / 100;
	const debug = {
		type: 'reading',
		provisional: !!message.provisional,
		// The cloud engine that read the dialogue, if one did.
		cloud: message.cloud ?? null,
		dialogue: readsDialogue,
		awaitingLine: ocr.awaitingLine,
		size: [message.width, message.height],
		recognized: message.lines,
		removed: message.removed ?? [],
		line: usesLine ? ocr.line : null,
		earlierLines: [],
	};
	// A reading while the text may still change (see settleAndRecognize in OCRController.swift) is only
	// taken when it matches the WebSocket line completely, new or not (e.g. the dialogue shown again
	// after a menu closed).
	if (message.provisional) {
		if (!readsDialogue || !usesLine) {
			logOcrDebug({ ...debug, outcome: 'not taken' });
			return;
		}
		const result = correctWithText(dialogue, ocr.line, minQuality);
		if (result.quality < minQuality || result.missingEnd > 0) {
			logOcrDebug({ ...debug, match: matchSummary(result), outcome: 'not taken' });
			return;
		}
		nativeCall('ocr', { action: 'accept' }).catch(() => {});
		// With a cloud engine, its reading of the dialogue is shown instead, once it answers.
		const cloud = getSettings().ocrCloudEngine;
		if (cloud && cloud !== 'none') {
			logOcrDebug({ ...debug, match: matchSummary(result), outcome: 'taken, for the cloud engine' });
			return;
		}
	}
	if (usesLine) {
		const result = correctWithText(dialogue, ocr.line, minQuality);
		debug.match = matchSummary(result);
		dialogue = correctWithEarlierLines(markMatch(result.lines, 0), minQuality, debug.earlierLines);
	}
	if (readsDialogue) {
		ocr.awaitingLine = false;
		ocr.stale = false;
	}
	const lines = [...dialogue, ...others];
	const size = { width: message.width, height: message.height };
	const key = JSON.stringify([lines, size]);
	// Unchanged (e.g. read again after coming back from another space): keep the hovered word and
	// its highlight as they are.
	const shown = lines.map((line) => ({ text: lineText(line), area: line.area, matched: !!line.matched }));
	if (key === ocr.key && $('#ocr-text').childElementCount > 0) {
		ocr.deferred = null;
		logOcrDebug({ ...debug, shown, outcome: 'unchanged' });
		return;
	}
	const highlighted = highlightedOcrChars();
	if (highlighted && hasCharsInPlace(lines, size, highlighted)) {
		ocr.deferred = { lines, size, key };
		logOcrDebug({ ...debug, shown, outcome: 'shown once the popups close' });
		return;
	}
	logOcrDebug({ ...debug, shown, outcome: 'shown' });
	ocr.deferred = null;
	renderOcrResult({ lines, size, key });
}

function renderOcrResult({ lines, size, key }) {
	ocr.key = key;
	ocr.size = size;
	const scanned = ocrScanPlace();
	renderLines($('#ocr-text'), lines);
	applyOcrScale();
	if (!moveOcrScan(scanned)) clearMainScan();
}

/**
 * Where in the OCR text the word shown in the popup (or being looked up) is: for its start and end, the line's
 * index and text and the offset in it. Null when there's none.
 */
function ocrScanPlace() {
	const range = scan.source?.range;
	const container = $('#ocr-text');
	if (!range || !container.contains(range.startContainer) || !container.contains(range.endContainer)) return null;
	const lines = [...container.querySelectorAll('.ocr-line')];
	const point = (node, offset) => {
		const line = (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement).closest('.ocr-line');
		const before = document.createRange();
		before.setStart(line, 0);
		before.setEnd(node, offset);
		return { index: lines.indexOf(line), text: line.textContent, offset: before.toString().length };
	};
	return { start: point(range.startContainer, range.startOffset), end: point(range.endContainer, range.endOffset) };
}

/**
 * Moves the word shown in the popup (or being looked up) to the new OCR text where it has the same lines as at
 * `place` (see ocrScanPlace), e.g. read again after coming back from another space but a pixel off, so its
 * highlight stays with the popup. Returns whether it did.
 */
function moveOcrScan(place) {
	if (!place) return false;
	const lines = [...$('#ocr-text').querySelectorAll('.ocr-line')];
	// A start at the beginning of its character's text, as a scan has it (see Yomitan's hasSameStart).
	const find = ({ index, text, offset }, isStart) => {
		// The same line, or else the only one with that text.
		const same = lines.filter((line) => line.textContent === text);
		const line = lines[index]?.textContent === text ? lines[index] : same.length === 1 ? same[0] : null;
		if (!line) return null;
		const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
		let left = offset;
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			if (left < node.length || (left === node.length && !isStart)) return { node, offset: left };
			left -= node.length;
		}
		return null;
	};
	const start = find(place.start, true);
	const end = find(place.end, false);
	if (!start || !end) return false;
	const range = scan.source.range;
	range.setStart(start.node, start.offset);
	range.setEnd(end.node, end.offset);
	// A lookup still going on highlights it when it's done.
	if (!scan.pending) setHighlight(scan.source);
	return true;
}

window.__macpopupOcr = (message) => {
	switch (message.type) {
		case 'window':
			setOcrWindow(message);
			break;
		case 'covered':
			ocr.covered = message.value;
			break;
		case 'changing':
			// Don't offer the old text while the window changes. It's replaced once the window is read,
			// unless it's still the same.
			ocr.stale = true;
			break;
		case 'result':
			showOcrResult(message);
			break;
		case 'error':
			log('OCR', message.message);
			showToast(message.message);
			break;
	}
};

// While WebSocket lines are used, the host reads the window when they arrive instead of watching it
// for changes all the time.
function updateOcrWebsocket() {
	const settings = getSettings();
	const connected = !!settings.ocrMode && !!settings.ocrUseWebsocket && !state.paused && [...sockets.values()].some((socket) => socket.state === 1);
	if (connected === ocr.websocketConnected) return;
	ocr.websocketConnected = connected;
	nativeCall('ocr', { action: 'websocket', connected }).catch(() => {});
}

function ocrLineText(rawText) {
	if (typeof rawText !== 'string') return null;
	const text = applyReplacements(rawText, getSettings().replacements);
	return text.trim() || null;
}

function ocrWebsocketLine(rawText) {
	const settings = getSettings();
	if (state.paused) return;
	const text = ocrLineText(rawText);
	if (text === null) return;
	logOcrDebug({ type: 'line', text, received: rawText });
	if (ocr.line !== null) ocr.earlierLines = [...ocr.earlierLines, ocr.line].slice(-Math.max(1, settings.ocrEarlierLines));
	ocr.line = text;
	if (!settings.ocrMode || !settings.ocrUseWebsocket) return;
	ocr.awaitingLine = true;
	clearOcrText();
	nativeCall('ocr', { action: 'cue' }).catch(() => {});
}

function ocrLineAt(x, y) {
	if (!getSettings().ocrMode || ocr.covered || $('#ocr-layer').hidden) return null;
	return document.elementFromPoint(x, y)?.closest('#ocr-text .ocr-line') ?? null;
}

function scanOcr(x, y, mods, lineElement) {
	const settings = getSettings();
	clearTimeout(scan.timer);
	if (ocr.stale || ocr.deferred) return;
	const input = matchScanInput(settings.scanModifier, settings.scanInputs, mods);
	if (input === null) return;
	const vertical = lineElement.style.writingMode === 'vertical-rl';
	const scanAtPoint = () => void scanSource(getTextSourceFromPoint(x, y), vertical, input);
	if (input.passive) {
		scan.timer = setTimeout(scanAtPoint, settings.scanDelay);
	} else {
		scanAtPoint();
	}
}

// Game controllers (Gamepads.swift). The host sends the held controls by GameController's names ("Button A",
// "Direction Pad Left", "Left Thumbstick Up"). The controller scan key's buttons give the text controller focus: the
// D-pad (or left stick) then moves through the text box or OCR Mode text, until they're pressed again. It moves by
// character (a cursor whose word is looked up once it rests) or by word, as Scan resolution says; either way, the
// popup opens once it rests for gamepadPopupDelay. Popup shortcuts can have buttons too. While the text has controller focus, or a popup with
// such shortcuts is open, the host holds the controllers, so the game doesn't get their presses.

const gamepad = {
	held: [],
	// The buttons held together since none were, which count as a combination once they're all let go.
	combo: [],
	focus: false,
	// By word: the word the controller is on (a TextSource), and the start of the word before each move forward, for
	// moving back.
	word: null,
	history: [],
	// By character: the character the cursor is on ({node, offset}, and its index for when the text is redrawn).
	cursor: null,
	lookupTimer: null,
	// The direction held, which repeats after a moment.
	direction: null,
	repeatTimer: null,
	// A move is being looked up; one more pressed meanwhile waits for it.
	moving: false,
	queued: null,
	// Whether the host was asked to hold the controllers.
	holding: null,
	// OCR Mode when the text got controller focus: switching drops it.
	ocrMode: null,
};

const isDirectionControl = (name) => /^(Direction Pad|Left Thumbstick|Right Thumbstick) (Up|Down|Left|Right)$/.test(name);

/** The direction of a control that moves through the text (the D-pad's, or the left stick's), or null. */
const moveDirection = (name) => /^(?:Direction Pad|Left Thumbstick) (Up|Down|Left|Right)$/.exec(name)?.[1] ?? null;

const sameButtons = (a, b) => a.length === b.length && a.every((name) => b.includes(name));

const movesByCharacter = () => getSettings().scanResolution !== 'word';

function controllerHotkeys() {
	return (getSettings().hotkeys ?? []).filter(({ enabled, buttons }) => enabled && Array.isArray(buttons) && buttons.length > 0);
}

function updateGamepadHold() {
	const hold = gamepad.focus || (popupManager.visiblePopups().length > 0 && controllerHotkeys().length > 0);
	if (hold === gamepad.holding) return;
	gamepad.holding = hold;
	nativeCall('gamepadHold', { hold }).catch(() => {});
}

window.__macpopupGamepad = (held) => {
	const before = gamepad.held;
	gamepad.held = held;
	// A combination counts once all its buttons are let go, as Settings records it: the buttons held together
	// meanwhile (a shortcut's buttons pressed with another one are a different combination).
	const buttons = held.filter((name) => !isDirectionControl(name));
	if (buttons.length > 0) {
		gamepad.combo = [...new Set([...gamepad.combo, ...buttons])];
	} else if (gamepad.combo.length > 0) {
		const combo = gamepad.combo;
		gamepad.combo = [];
		const scanButtons = getSettings().gamepadScanButtons ?? [];
		if (scanButtons.length > 0 && sameButtons(combo, scanButtons)) {
			setControllerFocus(!gamepad.focus);
		} else if (popupManager.visiblePopups().length > 0) {
			const hotkey = controllerHotkeys().find((hotkey) => sameButtons(combo, hotkey.buttons));
			if (hotkey) runHotkey(hotkey);
		}
	}
	const directions = held.map(moveDirection).filter(Boolean);
	const pressed = directions.find((direction) => !before.map(moveDirection).includes(direction));
	if (!gamepad.focus) return;
	if (pressed) holdDirection(pressed);
	else if (!directions.includes(gamepad.direction)) holdDirection(null);
};

function setControllerFocus(focus) {
	if (focus === gamepad.focus) return;
	holdDirection(null);
	clearTimeout(gamepad.lookupTimer);
	gamepad.word = null;
	gamepad.history = [];
	setTextCursor(null);
	if (focus) {
		if (controllerChars().length === 0) {
			showToast('No text to look up');
			return;
		}
		gamepad.focus = true;
		gamepad.ocrMode = !!getSettings().ocrMode;
		void moveController(null);
	} else {
		gamepad.focus = false;
		popupManager.closeAll();
		clearMainScan();
	}
	updateGamepadHold();
}

/** Moves in `direction` now, and again every 150 ms after it's held for 400 ms; null stops. */
function holdDirection(direction) {
	clearTimeout(gamepad.repeatTimer);
	gamepad.direction = direction;
	if (!direction) return;
	const step = () => {
		if (gamepad.moving) {
			gamepad.queued = direction;
			return;
		}
		void moveController(direction);
	};
	step();
	const repeat = () => {
		if (gamepad.direction !== direction) return;
		step();
		gamepad.repeatTimer = setTimeout(repeat, 150);
	};
	gamepad.repeatTimer = setTimeout(repeat, 400);
}

// The text

/** The lines the controller moves through: OCR Mode's text, or the text box's. */
function controllerLines() {
	if (getSettings().ocrMode) {
		if (ocr.covered || ocr.stale || $('#ocr-layer').hidden) return [];
		return [...$('#ocr-text').querySelectorAll('.ocr-line')];
	}
	return box.hidden ? [] : [...linesElement.querySelectorAll('p[data-line-id]')];
}

/** The characters of those lines in order, each {node, offset, line}: not spaces or furigana. */
function controllerChars() {
	const chars = [];
	for (const line of controllerLines()) {
		const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT, {
			acceptNode: (node) => (node.parentElement?.closest('rt, rp') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
		});
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			for (let offset = 0; offset < node.data.length; offset += node.data.codePointAt(offset) > 0xffff ? 2 : 1) {
				if (node.data[offset].trim()) chars.push({ node, offset, line });
			}
		}
	}
	return chars;
}

function charRange({ node, offset }) {
	const range = document.createRange();
	range.setStart(node, offset);
	range.setEnd(node, offset + (node.data.codePointAt(offset) > 0xffff ? 2 : 1));
	return range;
}

const charRect = (char) => charRange(char).getBoundingClientRect();

const isVerticalLine = (line) => (line.classList.contains('ocr-line') ? line.style.writingMode === 'vertical-rl' : !!getSettings().displayVertical);

/** Where the controller starts: the first character of the text box's newest line, or see firstOcrLine. */
function firstIndex(chars) {
	if (getSettings().ocrMode) return Math.max(0, chars.findIndex((char) => char.line === firstOcrLine(chars)));
	const newest = chars[getSettings().reverseLineOrder ? 0 : chars.length - 1];
	return chars.findIndex((char) => char.line === newest.line);
}

/**
 * The OCR line the controller starts on, in the dialogue area if it has text: the first line matched with the most
 * recent WebSocket line, or else the first line of the bottom or top paragraph (gamepadOcrStart; in vertical text, the
 * leftmost or rightmost).
 */
function firstOcrLine(chars) {
	const lines = [...new Set(chars.map((char) => char.line))];
	const dialogue = lines.filter((line) => line.dataset.area === '0');
	const candidates = dialogue.length > 0 ? dialogue : lines;
	const matched = candidates.filter((line) => line.dataset.match !== undefined);
	if (matched.length > 0) {
		const latest = Math.min(...matched.map((line) => Number(line.dataset.match)));
		return matched.find((line) => Number(line.dataset.match) === latest);
	}
	// Paragraphs are separated by "\n" text nodes (see renderLines).
	const paragraphs = [];
	let paragraph = [];
	for (const node of $('#ocr-text').childNodes) {
		if (node.nodeType === Node.TEXT_NODE) {
			if (paragraph.length > 0) paragraphs.push(paragraph);
			paragraph = [];
		} else if (candidates.includes(node)) {
			paragraph.push(node);
		}
	}
	if (paragraph.length > 0) paragraphs.push(paragraph);
	if (paragraphs.length === 0) return candidates[0];
	const vertical = isVerticalLine(paragraphs[0][0]);
	const top = getSettings().gamepadOcrStart === 'top';
	// How far toward the start position a paragraph reaches: down (or left in vertical text) for Bottom.
	const reach = (paragraph) => {
		const rects = paragraph.map((line) => line.getBoundingClientRect());
		if (vertical) return top ? Math.max(...rects.map((rect) => rect.right)) : -Math.min(...rects.map((rect) => rect.left));
		return top ? -Math.min(...rects.map((rect) => rect.top)) : Math.max(...rects.map((rect) => rect.bottom));
	};
	return paragraphs.reduce((best, paragraph) => (reach(paragraph) > reach(best) ? paragraph : best))[0];
}

/**
 * Where the controller's word (or else the word shown) is in `chars`: its first character's index, and the index after
 * it (-1 past the end).
 */
function controllerWord(chars) {
	const range = gamepad.word?.range ?? (popupManager.visiblePopups().length > 0 ? scan.source?.range : null);
	if (!range) return null;
	// Before the word, in it, or from its end on.
	const place = ({ node, offset }) => {
		const compared = range.comparePoint(node, offset);
		return compared === 0 && node === range.endContainer && offset === range.endOffset ? 1 : compared;
	};
	const start = chars.findIndex((char) => place(char) >= 0);
	if (start < 0 || place(chars[start]) !== 0) return null;
	return { start, next: chars.findIndex((char) => place(char) > 0) };
}

/**
 * The character `direction` goes to from `chars[index]`, or -1. Along the line (right in horizontal text, down in
 * vertical) is the next character, and back the one before; across lines, on the nearest line that way, the one
 * nearest along it.
 */
function charIndexToward(chars, index, direction) {
	const vertical = isVerticalLine(chars[index].line);
	if (direction === (vertical ? 'Down' : 'Right')) return index + 1 < chars.length ? index + 1 : -1;
	if (direction === (vertical ? 'Up' : 'Left')) return index - 1;
	const upDown = direction === 'Up' || direction === 'Down';
	const sign = direction === 'Down' || direction === 'Right' ? 1 : -1;
	const along = (rect) => (upDown ? rect.top + rect.height / 2 : rect.left + rect.width / 2);
	const across = (rect) => (upDown ? rect.left + rect.width / 2 : rect.top + rect.height / 2);
	const from = charRect(chars[index]);
	const size = upDown ? from.height : from.width;
	const ahead = chars
		.map((char, i) => ({ i, rect: charRect(char) }))
		.map((char) => ({ ...char, distance: sign * (along(char.rect) - along(from)) }))
		.filter(({ distance }) => distance > size / 2);
	if (ahead.length === 0) return -1;
	const nearest = Math.min(...ahead.map(({ distance }) => distance));
	const line = ahead.filter(({ distance }) => distance <= nearest + size / 2);
	return line.reduce((best, char) => (Math.abs(across(char.rect) - across(from)) < Math.abs(across(best.rect) - across(from)) ? char : best)).i;
}

/** Scrolls the text box so a character in it shows. */
function scrollToChar(char) {
	if (!linesElement.contains(char.node)) return;
	const rect = charRect(char);
	const view = linesElement.getBoundingClientRect();
	if (rect.top < view.top) linesElement.scrollTop -= view.top - rect.top;
	else if (rect.bottom > view.bottom) linesElement.scrollTop += rect.bottom - view.bottom;
	if (rect.left < view.left) linesElement.scrollLeft -= view.left - rect.left;
	else if (rect.right > view.right) linesElement.scrollLeft += rect.right - view.right;
}

/**
 * Looks up the word starting at a character, showing its popup after `delay`. Returns whether there's one.
 * @param {() => void} [onFound] Called as soon as the word is found and highlighted (before its popup shows).
 */
async function lookUpAt(char, delay = 0, onFound = undefined) {
	scrollToChar(char);
	const source = textSourceAt(char.node, char.offset);
	const found = await scanSource(source, isVerticalLine(char.line), undefined, { quiet: true, delay, onFound });
	if (found && !movesByCharacter()) {
		gamepad.word = scan.source;
		// Without "Select matched text", the cursor's highlight shows which word the controller is on.
		highlightCursor(getSettings().selectMatchedText ? null : scan.source.range.cloneRange());
	}
	return found;
}

const popupDelay = () => Math.max(0, Number(getSettings().gamepadPopupDelay) || 0);

function moveController(direction) {
	return movesByCharacter() ? moveCursor(direction) : moveWord(direction);
}

// Moving by word

/**
 * Looks up the word at `chars[index]`, or else at the next character in `step` (1 or -1) where there's one, within 20
 * characters (e.g. past punctuation). Returns whether it found one.
 */
async function lookUpFrom(chars, index, step) {
	for (let i = index, tries = 0; i >= 0 && i < chars.length && tries < 20; i += step, tries++) {
		const found = await lookUpAt(chars[i], popupDelay());
		if (!gamepad.focus) return false;
		if (found) return true;
	}
	return false;
}

/**
 * Moves to the word in `direction`: along the line to the next word (from where the controller's word ends) or back to
 * the one before (the word it moved on from, or else the nearest character before it with one), across lines to the
 * nearest character's. Null looks up the word shown again, or else the first one. The word is highlighted at once, and
 * its popup opens once the controller rests for gamepadPopupDelay (the popup shown closes at the move).
 */
async function moveWord(direction) {
	gamepad.moving = true;
	try {
		// A reading that waited for the popups to close (see ocr.deferred) is the text to move through.
		if (ocr.deferred) applyDeferredOcr();
		const chars = controllerChars();
		if (chars.length === 0) return;
		const word = controllerWord(chars);
		if (direction && word && popupDelay() > 0) popupManager.closeAll();
		if (!word) {
			gamepad.word = null;
			gamepad.history = [];
			await lookUpFrom(chars, firstIndex(chars), 1);
			return;
		}
		if (!direction) return;
		const start = chars[word.start];
		const vertical = isVerticalLine(start.line);
		if (direction === (vertical ? 'Down' : 'Right')) {
			if (word.next < 0) return;
			gamepad.history.push({ node: start.node, offset: start.offset });
			await lookUpFrom(chars, word.next, 1);
		} else if (direction === (vertical ? 'Up' : 'Left')) {
			const previous = gamepad.history.pop();
			const index = previous ? chars.findIndex((char) => char.node === previous.node && char.offset === previous.offset) : -1;
			if (index >= 0) {
				await lookUpFrom(chars, index, 1);
			} else {
				gamepad.history = [];
				if (word.start > 0) await lookUpFrom(chars, word.start - 1, -1);
			}
		} else {
			const index = charIndexToward(chars, word.start, direction);
			if (index < 0) return;
			gamepad.history = [];
			await lookUpFrom(chars, index, 1);
		}
	} finally {
		gamepad.moving = false;
		const queued = gamepad.queued;
		gamepad.queued = null;
		if (queued && gamepad.focus) void moveController(queued);
	}
}

// Moving by character

let cursorHighlight = null;

/** Shows the controller's place in the text (a range, or null for none) with the macpopup-gamepad highlight. */
function highlightCursor(range) {
	if (typeof CSS === 'undefined' || !CSS.highlights) return;
	if (cursorHighlight === null) {
		cursorHighlight = new Highlight();
		CSS.highlights.set('macpopup-gamepad', cursorHighlight);
	}
	cursorHighlight.clear();
	if (range) cursorHighlight.add(range);
}

/** Puts the cursor on a character of `chars` (null removes it). */
function setTextCursor(char, index = -1) {
	gamepad.cursor = char && { node: char.node, offset: char.offset, index };
	highlightCursor(char && charRange(char));
}

/** The cursor's index in `chars`: where its character is, else (the text was redrawn) the same index. */
function cursorIndex(chars) {
	const { node, offset, index } = gamepad.cursor;
	const found = chars.findIndex((char) => char.node === node && char.offset === offset);
	return found >= 0 ? found : Math.min(Math.max(index, 0), chars.length - 1);
}

/**
 * Moves the cursor a character in `direction` (see charIndexToward), closing the popups, and looks up the word starting
 * there once it rests for gamepadPopupDelay. Null starts it: at the start of the word shown (e.g. after switching from
 * moving by word), or else at the first character.
 */
function moveCursor(direction) {
	clearTimeout(gamepad.lookupTimer);
	if (popupManager.visiblePopups().length > 0 || scan.pending) {
		// A popup for where the cursor was doesn't open after it moved on. (A reading that waited for the popups to
		// close is drawn now, so the cursor keeps its index in it.)
		popupManager.closeAll();
		clearMainScan();
	}
	const chars = controllerChars();
	if (chars.length === 0) return;
	let index;
	if (gamepad.cursor) {
		index = cursorIndex(chars);
		if (direction) index = charIndexToward(chars, index, direction);
		if (index < 0) return;
	} else {
		index = controllerWord(chars)?.start ?? firstIndex(chars);
	}
	setTextCursor(chars[index], index);
	scrollToChar(chars[index]);
	gamepad.lookupTimer = setTimeout(() => void lookUpCursor(), popupDelay());
}

async function lookUpCursor() {
	if (!gamepad.focus || !gamepad.cursor) return;
	const chars = controllerChars();
	if (chars.length === 0) return;
	const index = cursorIndex(chars);
	setTextCursor(chars[index], index);
	// The matched word's highlight shows where the cursor is, from when it's found.
	await lookUpAt(chars[index], 0, () => {
		if (gamepad.cursor?.index === index && getSettings().selectMatchedText) highlightCursor(null);
	});
}

// Settings

function applySettings(settings) {
	document.documentElement.dataset.theme = settings.theme;
	// For the fonts' glyph shapes, e.g. Chinese or Japanese forms of the same character.
	const lang = settings.language === 'xxx' ? '' : settings.language;
	document.documentElement.lang = lang;
	$('#ocr-text').lang = lang;
	const shown = box.hidden && !settings.ocrMode;
	box.hidden = !!settings.ocrMode;
	$('#ocr-layer').classList.toggle('show-boxes', !!settings.ocrShowBoxes);
	if (!settings.ocrMode) setOcrWindow({ visible: false });
	box.style.setProperty('--box-opacity', `${settings.boxOpacity}`);
	linesElement.style.fontSize = `${settings.fontSize}px`;
	linesElement.style.fontFamily = settings.onlineFont !== 'Off' ? `'${settings.onlineFont}'` : '';
	linesElement.style.writingMode = settings.displayVertical ? 'vertical-rl' : 'horizontal-tb';
	$('#user-css').textContent = settings.customCSS;
	$('#popup-outer-custom-css').textContent = settings.customPopupOuterCss;
	applyBoxRect(settings.boxRect ?? defaultBoxRect());

	const renderKey = JSON.stringify([
		settings.showFurigana,
		settings.furiganaReadingMode,
		settings.termSpacing,
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
	// It doesn't scroll while it's hidden in OCR mode, which keeps adding lines.
	if (shown) scrollToEnd();
	syncSockets();
	updateOcrWebsocket();
	renderClipboardButton();
	popupManager.applySettings();
	reportHitRects();
	// Without the scan key's buttons, or in the other mode, the text no longer has controller focus.
	if (gamepad.focus && ((settings.gamepadScanButtons ?? []).length === 0 || !!settings.ocrMode !== gamepad.ocrMode)) setControllerFocus(false);
	updateHotkeys();
}

function renderClipboardButton() {
	const button = $('#clipboard-button');
	const enabled = !!getSettings().clipboardMonitor;
	button.innerHTML = icon(enabled ? mdiClipboardTextOutline : mdiClipboardOffOutline);
	button.title = 'Clipboard';
	button.classList.toggle('text-green-700', enabled);
}

function renderPauseButton() {
	const button = $('#pause-button');
	button.innerHTML = icon(state.paused ? mdiPlay : mdiPause);
	button.title = state.paused ? 'Resume' : 'Pause';
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
		updateOcrWebsocket();
	});
	$('#clipboard-button').addEventListener('click', () => void saveSettings({ clipboardMonitor: !getSettings().clipboardMonitor }));
	$('#clear-button').addEventListener('click', clearLines);
	$('#settings-button').addEventListener('click', () => nativeCall('openSettings'));
	$('#hide-button').addEventListener('click', () => nativeCall('setOverlayVisible', { visible: false }));
	setUpDrag($('#drag-handle'), (rect, dx, dy) => ({ ...rect, x: rect.x + dx, y: rect.y + dy }));
	setUpDrag($('#resize-handle'), (rect, dx, dy) => ({ ...rect, width: rect.width + dx, height: rect.height + dy }));
	linesElement.addEventListener('pointerdown', () => popupManager.closeAll());
	// Scrolling by hand moves the looked-up word; scrolling to show new lines keeps the popup open.
	linesElement.addEventListener('wheel', () => popupManager.closeAll(), { passive: true });
	window.addEventListener('resize', () => applyBoxRect(getSettings().boxRect ?? defaultBoxRect()));

	applySettings(settings);
	nativeCall('ocr', { action: 'ready' }).catch(() => {});
}

main().catch((e) => log('Overlay failed to start', e));
