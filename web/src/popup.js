// The Yomitan-style popup page, loaded in an iframe by the overlay (see overlay.js PopupManager).
// Entries are rendered by Yomitan's own DisplayGenerator, so the DOM matches Yomitan's popup
// and Yomitan custom CSS applies as-is. This replaces Yomitan's Display/DisplayAnki/DisplayAudio.
import './lib/chrome-shim.js';
import { DisplayContentManager } from '../../vendor/yomitan/ext/js/display/display-content-manager.js';
import { DisplayGenerator } from '../../vendor/yomitan/ext/js/display/display-generator.js';
import { DisplayNotification } from '../../vendor/yomitan/ext/js/display/display-notification.js';
import { ElementOverflowController } from '../../vendor/yomitan/ext/js/display/element-overflow-controller.js';
import { PopupMenu } from '../../vendor/yomitan/ext/js/dom/popup-menu.js';
import { base64ToArrayBuffer } from '../../vendor/yomitan/ext/js/data/array-buffer-util.js';
import { addScopeToCss } from '../../vendor/yomitan/ext/js/core/utilities.js';
import { ankiInvoke, findNoteIds, getNoteInfos, suspendCardsForNote } from './lib/anki-connect.js';
import { buildFirstFieldNotes, buildNote, overwriteNote, storeMedia } from './lib/anki-notes.js';
import { log, nativeCall } from './lib/native.js';
import { matchScanInput, preventRightClickSelection } from './lib/scan-inputs.js';
import { adaptCssForWebKit } from './lib/webkit-css.js';
import { getTextSourceFromPoint, searchTextSource, setHighlight, wrapRubyBases } from './lib/scanner.js';
import { getSettings, setLocalSettings } from './lib/settings.js';
import { ankiFields, kanjiEntries } from './lib/yomitan-api.js';
import { getAudio, getAudioSources, getLoadedInfoList, loadInfoList, startAudio } from './lib/audio-sources.js';
import { cursorAt } from './lib/cursor.js';

const overlay = () => window.parent.macpopupOverlay;

const flagNames = { 1: 'Red', 2: 'Orange', 3: 'Green', 4: 'Blue', 5: 'Pink', 6: 'Turquoise', 7: 'Purple' };
const flagColors = {
	Red: 'rgb(248, 113, 113)',
	Orange: 'rgb(253, 186, 116)',
	Green: 'rgb(134, 239, 172)',
	Blue: 'rgb(96, 165, 250)',
	Pink: 'rgb(240, 171, 252)',
	Turquoise: 'rgb(94, 234, 212)',
	Purple: 'rgb(192, 132, 252)',
};

function splitTags(text) {
	return `${text ?? ''}`.split(/[,\s]+/).filter((tag) => tag.length > 0);
}

/** The state shown for a note's cards, the most advanced first, as Yomitan's DisplayAnki._getHighestPriorityCardState. */
function getCardState(cardStates) {
	if (cardStates.includes(-3) || cardStates.includes(-2)) return 'buried';
	if (cardStates.includes(-1)) return 'suspended';
	if (cardStates.includes(2)) return 'review';
	if (cardStates.includes(1) || cardStates.includes(3)) return 'learning';
	return 'new';
}

// The canvas element each OffscreenCanvas came from, since media requests only carry the latter.
const canvasElements = new WeakMap();
const transferControlToOffscreen = HTMLCanvasElement.prototype.transferControlToOffscreen;
HTMLCanvasElement.prototype.transferControlToOffscreen = function () {
	const offscreen = transferControlToOffscreen.call(this);
	canvasElements.set(offscreen, this);
	return offscreen;
};

/** Loads structured-content images through the Yomitan API instead of the extension backend. */
class PopupContentManager extends DisplayContentManager {
	constructor(popup) {
		super(null);
		this._popup = popup;
	}

	async executeMediaRequests() {
		const requests = this._loadMediaRequests;
		this._loadMediaRequests = [];
		if (requests.length === 0) return;
		const token = this._token;
		let media;
		try {
			media = await this._popup.getDictionaryMedia();
		} catch (e) {
			log('Failed to load dictionary media', e);
			return;
		}
		if (token !== this._token) return;
		for (const { path, dictionary, canvas } of requests) {
			const item = media.find((value) => value.path === path && value.dictionary === dictionary);
			if (!item) continue;
			// Yomitan colors monochrome images with a CSS filter whose drop-shadow WebKit leaves out
			// when it draws the canvas on the GPU (they show black), so they're colored here instead.
			const element = canvasElements.get(canvas);
			const color = element?.closest('.gloss-image-link')?.dataset.appearance === 'monochrome'
				? getComputedStyle(element).getPropertyValue('--text-color').trim() || getComputedStyle(element).color
				: null;
			try {
				await drawMediaToCanvas(item, canvas, color);
			} catch (e) {
				log('Failed to draw dictionary media', e);
			}
		}
	}

	async openMediaInTab() {}

	_onLinkClick(e) {
		const { href } = e.currentTarget;
		if (typeof href !== 'string') return;
		const url = new URL(href, location.href);
		if (url.protocol !== location.protocol || url.host !== location.host) return;
		e.preventDefault();
		const query = url.searchParams.get('query');
		if (query) void this._popup.searchQuery(query);
	}
}

/** @param {string | null} color Fills the image's shape with this color (for monochrome images). */
async function drawMediaToCanvas(item, canvas, color = null) {
	const blob = new Blob([base64ToArrayBuffer(item.content)], { type: item.mediaType });
	let image;
	try {
		image = await createImageBitmap(blob);
	} catch (_) {
		// createImageBitmap can't decode SVG.
		image = new Image();
		image.src = URL.createObjectURL(blob);
		await image.decode();
	}
	const context = canvas.getContext('2d');
	context.clearRect(0, 0, canvas.width, canvas.height);
	context.drawImage(image, 0, 0, canvas.width, canvas.height);
	if (color) {
		context.globalCompositeOperation = 'source-in';
		context.fillStyle = color;
		context.fillRect(0, 0, canvas.width, canvas.height);
		context.globalCompositeOperation = 'source-over';
	}
}

/**
 * Yomitan's ElementOverflowController checks whether each definition is long enough to collapse as
 * it's added, reading its height right after changing its classes, so WebKit lays the whole popup out
 * again for every definition (hundreds of milliseconds for a long popup). This checks the definitions
 * added since the last `flush` together, with one layout. Each check only depends on the definition's
 * own size, so the result is the same.
 */
class BatchedOverflowController extends ElementOverflowController {
	constructor(display) {
		super(display);
		this.pending = [];
	}

	_updateElement(element) {
		this.pending.push(element);
	}

	_update() {
		super._update();
		this.flush();
	}

	clearElements() {
		super.clearElements();
		this.pending = [];
	}

	flush() {
		const elements = this.pending;
		this.pending = [];
		for (const element of elements) element.classList.add('collapse-test');
		const collapsible = elements.map((element) => element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth);
		elements.forEach((element, i) => {
			element.classList.toggle('collapsible', collapsible[i]);
			element.classList.remove('collapse-test');
		});
	}
}

/**
 * Resolves once what was changed so far has been painted (a timer alone can run before the next
 * frame), or after 100 ms if no frame comes.
 */
function afterNextPaint() {
	return new Promise((resolve) => {
		const timer = setTimeout(resolve, 100);
		requestAnimationFrame(() => setTimeout(() => {
			clearTimeout(timer);
			resolve();
		}, 0));
	});
}

// Custom popup CSS followed by each dictionary's styles, scoped to its entries like Yomitan's
// Display._getCustomCss.
function getCustomCss(settings) {
	let css = adaptCssForWebKit(settings.customPopupCss);
	for (const { name, styles } of settings.dictionaryStyles ?? []) {
		const escapedTitle = name.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
		css += '\n' + addScopeToCss(adaptCssForWebKit(styles), `[data-dictionary="${escapedTitle}"]`);
	}
	return css;
}

function resolveTheme(theme, siteTheme) {
	switch (theme) {
		case 'site':
			return siteTheme;
		case 'browser':
			return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
		default:
			return theme;
	}
}

// WebKit only delivers mouse moves to the key window, and the overlay never is, so :hover never
// applies in popups. Selectors are rewritten to .pointer-hover, which follows the cursor position the
// overlay forwards (see Popup.setPointerHover).
function emulateHover(rules) {
	for (const rule of rules) {
		if (rule instanceof CSSStyleRule && rule.selectorText.includes(':hover')) {
			rule.selectorText = rule.selectorText.replace(/:hover\b/g, '.pointer-hover');
		}
		if (rule.cssRules) emulateHover(rule.cssRules);
	}
}

function emulateHoverInStyleSheets() {
	for (const sheet of document.styleSheets) {
		try {
			emulateHover(sheet.cssRules);
		} catch (_) {
			// Not loaded.
		}
	}
}

// PopupMenu places menus at fractional positions. WebKit then draws their text half a pixel off while
// a hover transition runs (the menu gets a layer of its own for it), so the text shook as the pointer
// moved over the items. Whole points draw the same either way.
function roundMenuPosition(menu) {
	const { style } = menu.node;
	style.left = `${Math.round(Number.parseFloat(style.left) || 0)}px`;
	style.top = `${Math.round(Number.parseFloat(style.top) || 0)}px`;
}

class Popup {
	constructor() {
		this.depth = 0;
		this.history = [];
		this.historyIndex = -1;
		this.entryNodes = [];
		this.index = 0;
		this.renderToken = null;
		this.cardFormats = [];
		this.noteDetails = new Map();
		this.audio = null;
		this.audioCache = new Map();
		// term + reading → the audio chosen in the play button menu for Anki cards: {sourceIndex, subIndex, audio}.
		this.primaryCardAudio = new Map();
		this.openAudioMenus = new Set();
		this.dictionaryMediaPromise = null;
		this.notifications = { tag: null, inflection: null, error: null, tags: null, flags: null };
		this.scanTimer = null;
		this.scanSource = null;
		this.scanToken = 0;
		this.progressCount = 0;

		this.contentManager = new PopupContentManager(this);
		this.generator = new DisplayGenerator(this.contentManager, null);
		this.overflowController = new BatchedOverflowController(this);
		this.container = document.querySelector('#dictionary-entries');
		this.footer = document.querySelector('#content-footer');
		this.progressIndicator = document.querySelector('#progress-indicator');
		this.pointerHovered = new Set();
		this.ready = this.prepare();
	}

	get content() {
		return this.history[this.historyIndex] ?? null;
	}

	async prepare() {
		await this.generator.prepare();
		if (document.readyState !== 'complete') await new Promise((resolve) => window.addEventListener('load', resolve, { once: true }));
		emulateHoverInStyleSheets();
		const data = document.documentElement.dataset;
		data.browser = 'safari';
		data.platform = 'mac';

		document.querySelector('#close-button').addEventListener('click', () => overlay().closePopup(this.depth));
		document.querySelector('#navigate-previous-button').addEventListener('click', () => this.navigate(-1));
		document.querySelector('#navigate-next-button').addEventListener('click', () => this.navigate(1));
		// Right-button scan inputs shouldn't open the context menu or select the word.
		preventRightClickSelection(document, getSettings);
		document.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
		document.documentElement.addEventListener('click', (e) => {
			if (e.button !== 0) return;
			this.clearScan();
			overlay().closePopupsAbove(this.depth);
			void this.searchAtClick(e);
		});
		this.setUpResizer();
	}

	/** Called by DisplayContentManager links and ElementOverflowController. */
	scrollUpToElementTop(element) {
		const scroll = document.querySelector('#content-scroll');
		const top = element.getBoundingClientRect().top - scroll.getBoundingClientRect().top;
		if (top < 0) scroll.scrollTop += top;
	}

	configure({ depth }) {
		this.depth = depth;
	}

	applySettings(settings, { siteTheme }) {
		setLocalSettings(settings);
		const root = document.documentElement;
		const data = root.dataset;
		data.ankiEnabled = `${settings.ankiEnabled}`;
		data.language = settings.language;
		this.generator.updateLanguage(settings.language);
		// The API returns entries grouped as the Yomitan profile says; Import Yomitan copies that mode.
		data.resultOutputMode = settings.yomitanAnkiTemplates?.resultOutputMode ?? 'group';
		data.glossaryLayoutMode = settings.glossaryLayoutMode;
		data.compactTags = `${settings.compactTags}`;
		data.averageFrequency = `${settings.averageFrequency}`;
		data.frequencyDisplayMode = settings.frequencyDisplayMode;
		data.termDisplayMode = settings.termDisplayMode;
		data.enableSearchTags = `${settings.showSearchTags}`;
		data.audioEnabled = `${settings.audioEnabled !== false}`;
		data.showPronunciationText = `${settings.showPitchAccentDownstepNotation}`;
		data.showPronunciationDownstepPosition = `${settings.showPitchAccentPositionNotation}`;
		data.showPronunciationGraph = `${settings.showPitchAccentGraph}`;
		data.debug = 'false';
		data.popupDisplayMode = settings.popupDisplayMode;
		data.popupCurrentIndicatorMode = settings.popupCurrentIndicatorMode;
		data.popupActionBarVisibility = settings.popupActionBarVisibility;
		data.popupActionBarLocation = settings.popupActionBarLocation;

		data.theme = resolveTheme(settings.popupTheme, siteTheme);
		data.outerTheme = resolveTheme(settings.popupOuterTheme, siteTheme);
		data.siteTheme = siteTheme;
		data.browserTheme = resolveTheme('browser', siteTheme);
		data.themeRaw = settings.popupTheme;
		data.outerThemeRaw = settings.popupOuterTheme;

		root.style.fontFamily = settings.fontFamily;
		root.style.fontSize = `${settings.popupFontSize}px`;
		root.style.lineHeight = settings.lineHeight;
		document.body.style.fontSize = `${settings.popupScalingFactor}em`;
		document.querySelector('#custom-popup-css').textContent = getCustomCss(settings);
		emulateHoverInStyleSheets();
	}

	// Content

	async setContent(content, historyMode = 'clear') {
		if (historyMode === 'clear') {
			this.history = [content];
			this.historyIndex = 0;
		} else {
			this.history = this.history.slice(0, this.historyIndex + 1);
			this.history.push(content);
			this.historyIndex = this.history.length - 1;
		}
		await this.render();
	}

	navigate(direction) {
		const index = this.historyIndex + direction;
		if (index < 0 || index >= this.history.length) return;
		this.historyIndex = index;
		void this.render();
	}

	async searchQuery(query) {
		const content = this.content;
		const result = await overlay().lookupText(query);
		if (!result) return;
		await this.setContent({
			...result,
			sentence: content?.sentence ?? { text: query, offset: 0 },
			documentTitle: content?.documentTitle ?? '',
			player: content?.player ?? null,
		}, 'new');
	}

	async render() {
		const token = {};
		this.renderToken = token;
		const content = this.content;
		const settings = getSettings();

		this.stopAudio();
		this.closeAudioMenus();
		this.closeNotifications();
		this.clearScan();
		overlay()?.closePopupsAbove(this.depth);
		this.contentManager.unloadAll();
		this.overflowController.clearElements();
		this.container.textContent = '';
		this.entryNodes = [];
		this.noteDetails.clear();
		this.dictionaryMediaPromise = null;

		const { dictionaryEntries } = content;
		document.querySelector('#no-results').hidden = dictionaryEntries.length > 0;
		document.querySelector('#error-api').hidden = true;
		this.updateNavigation();

		const dictionaries = new Set();
		for (const entry of dictionaryEntries) {
			if (entry.type === 'term') {
				for (const definition of entry.definitions) dictionaries.add(definition.dictionary);
			} else {
				dictionaries.add(entry.dictionary);
			}
		}
		// Each dictionary's mode from Yomitan (see Import), or the one for all others.
		const collapsible = new Map((settings.dictionaryCollapsible ?? []).map(({ name, mode }) => [name, mode]));
		this.overflowController.setOptions({
			dictionaries: [...dictionaries].map((name) => ({ name, definitionsCollapsible: collapsible.get(name) ?? settings.definitionsCollapsible })),
		});

		this.setCurrentEntry(0);
		document.querySelector('#content-scroll').scrollTop = 0;
		// As in Yomitan's Display, the first entry is shown without waiting for the rest. The rest follow in
		// parts of about 30 ms each, counting their layout, which takes longer than making them: the
		// overlay's pointer updates wait for each part, so leaving the popup for another word isn't held up
		// until a long popup is done. A part has at most twice the entries of the one before, as an entry
		// can take much longer than the ones before it. (Yomitan adds each on its own, but a layout and
		// paint for each one makes long popups take twice as long to finish here.)
		let partStart = performance.now();
		let partFirst = 0;
		let partEnd = 1;
		for (let i = 0; i < dictionaryEntries.length; ++i) {
			if (i === partEnd) {
				this.overflowController.flush();
				// Lays the part out now, to time it.
				void this.container.offsetHeight;
				const count = i - partFirst;
				const perEntry = (performance.now() - partStart) / count;
				partFirst = i;
				partEnd = i + Math.max(1, Math.min(2 * count, Math.floor(30 / perEntry)));
				void this.contentManager.executeMediaRequests();
				await afterNextPaint();
				if (token !== this.renderToken) return;
				partStart = performance.now();
			}
			const dictionaryEntry = dictionaryEntries[i];
			const entry = dictionaryEntry.type === 'term'
				? this.generator.createTermEntry(dictionaryEntry, [])
				: this.generator.createKanjiEntry(dictionaryEntry, []);
			entry.dataset.index = `${i}`;
			wrapRubyBases(entry);
			this.addEntryEventListeners(entry);
			this.container.appendChild(entry);
			this.entryNodes.push(entry);
			if (i === this.index) entry.classList.add('entry-current');
			this.overflowController.addElements(entry);
		}
		this.overflowController.flush();
		void this.contentManager.executeMediaRequests();

		if (settings.audioEnabled !== false && settings.audioAutoPlay && content.type === 'term' && dictionaryEntries.length > 0) {
			void this.playAudio(0, 0);
		}
		await this.updateAnki(token);
	}

	/**
	 * Stops rendering the content and loading its media and Anki notes, e.g. when the popup is hidden: the
	 * page's other work, such as the next lookup, would wait for them. Showing the popup again sets its
	 * content again.
	 */
	stopRendering() {
		this.renderToken = null;
		this.contentManager.unloadAll();
	}

	updateNavigation() {
		const previous = this.historyIndex > 0;
		const next = this.historyIndex < this.history.length - 1;
		document.querySelector('#navigate-previous-button').disabled = !previous;
		document.querySelector('#navigate-next-button').disabled = !next;
		document.documentElement.dataset.hasNavigationPrevious = `${previous}`;
		document.documentElement.dataset.hasNavigationNext = `${next}`;
	}

	setCurrentEntry(index) {
		this.entryNodes[this.index]?.classList.remove('entry-current');
		this.entryNodes[index]?.classList.add('entry-current');
		this.index = index;
	}

	getEntryIndex(node) {
		const entry = node.closest('.entry');
		const index = entry ? Number.parseInt(entry.dataset.index, 10) : -1;
		return Number.isFinite(index) ? index : -1;
	}

	addEntryEventListeners(entry) {
		entry.addEventListener('click', (e) => {
			if (e.button === 0) this.setCurrentEntry(this.getEntryIndex(entry));
		});
		for (const node of entry.querySelectorAll('.headword-kanji-link')) {
			node.addEventListener('click', (e) => {
				e.preventDefault();
				void this.lookupKanji(node.textContent ?? '');
			});
		}
		for (const node of entry.querySelectorAll('.inflection[data-reason]')) {
			node.addEventListener('click', () => this.showInflectionNotification(node));
		}
		for (const node of entry.querySelectorAll('.tag-label')) {
			node.addEventListener('click', () => this.showTagNotification(node));
		}
		for (const button of entry.querySelectorAll('.action-button[data-action=play-audio]')) {
			const headword = button.closest('.headword');
			const headwordIndex = headword ? Number.parseInt(headword.dataset.index, 10) || 0 : 0;
			button.addEventListener('click', (e) => {
				e.preventDefault();
				void this.playAudio(this.getEntryIndex(entry), headwordIndex);
			});
			// Right-click lists the audio sources, as in Yomitan.
			button.addEventListener('contextmenu', (e) => {
				e.preventDefault();
				e.stopPropagation();
				this.showAudioMenu(button, this.getEntryIndex(entry), headwordIndex);
			});
			button.addEventListener('menuClose', (e) => this.onAudioMenuClose(e, this.getEntryIndex(entry), headwordIndex));
		}
	}

	async lookupKanji(character) {
		if (!character) return;
		const content = this.content;
		try {
			const dictionaryEntries = await kanjiEntries(character);
			await this.setContent({
				type: 'kanji',
				dictionaryEntries,
				query: character,
				fullQuery: character,
				sentence: content?.sentence ?? { text: character, offset: 0 },
				documentTitle: content?.documentTitle ?? '',
				player: content?.player ?? null,
			}, 'new');
		} catch (e) {
			this.showError(e);
		}
	}

	showError(error) {
		document.querySelector('#error-api').hidden = false;
		document.querySelector('#error-api-message').textContent = error instanceof Error ? error.message : `${error}`;
	}

	setProgress(active) {
		this.progressCount = Math.max(0, this.progressCount + (active ? 1 : -1));
		const visible = this.progressCount > 0;
		this.progressIndicator.hidden = !visible;
		this.progressIndicator.dataset.active = `${visible}`;
	}

	getDictionaryMedia() {
		if (this.dictionaryMediaPromise === null) {
			const content = this.content;
			this.dictionaryMediaPromise = ankiFields({
				text: content.query,
				type: content.type,
				markers: [],
				maxEntries: content.dictionaryEntries.length,
				includeMedia: true,
			}).then((result) => result.dictionaryMedia ?? []);
		}
		return this.dictionaryMediaPromise;
	}

	// Notifications

	createNotification(scannable) {
		const node = this.generator.createEmptyFooterNotification();
		if (scannable) node.classList.add('click-scannable');
		return new DisplayNotification(this.footer, node);
	}

	closeNotifications() {
		for (const notification of Object.values(this.notifications)) notification?.close(false);
	}

	showTagNotification(tagNode) {
		const parent = tagNode.parentNode;
		if (!(parent instanceof HTMLElement)) return;
		this.notifications.tag ??= this.createNotification(true);
		const dictionaryEntry = this.content.dictionaryEntries[this.getEntryIndex(parent)] ?? null;
		this.notifications.tag.setContent(this.generator.createTagFooterNotificationDetails(parent, dictionaryEntry));
		this.notifications.tag.open();
	}

	showInflectionNotification(node) {
		if (!node.title) return;
		this.notifications.inflection ??= this.createNotification(true);
		this.notifications.inflection.setContent(node.title);
		this.notifications.inflection.open();
	}

	showMessageNotification(name, message) {
		this.notifications[name] ??= this.createNotification(true);
		this.notifications[name].setContent(message);
		this.notifications[name].open();
	}

	showErrorNotification(errors) {
		this.notifications.error ??= this.createNotification(false);
		const content = this.generator.createAnkiNoteErrorsNotificationContent(errors);
		for (const link of content.querySelectorAll('.anki-note-error-log-link')) {
			link.addEventListener('click', () => log(...errors));
		}
		this.notifications.error.setContent(content);
		this.notifications.error.open();
	}

	// Audio

	get volume() {
		const { audioVolume } = getSettings();
		return Number.isFinite(audioVolume) ? Math.max(0, Math.min(100, audioVolume)) / 100 : 1;
	}

	/** Yomitan's audio fallback sound, played when no audio is found. */
	playFallbackSound() {
		const sound = getSettings().audioFallbackSound;
		if (sound !== 'click' && sound !== 'bloop') return;
		this.stopAudio();
		this.audio = new Audio(`/data/audio/fallback-${sound}.mp3`);
		this.audio.volume = this.volume;
		this.audio.play().catch((e) => log('Audio playback failed', e));
	}

	stopAudio() {
		if (this.audio) {
			this.audio.pause();
			this.audio = null;
		}
	}

	async fetchAudio(text, maxEntries) {
		const result = await ankiFields({ text, type: 'term', markers: ['audio'], maxEntries, includeMedia: true });
		for (const media of result.audioMedia ?? []) {
			this.audioCache.set(`${media.term}\u0000${media.reading}`, media);
		}
	}

	async playAudio(entryIndex, headwordIndex) {
		const content = this.content;
		const dictionaryEntry = content?.dictionaryEntries[entryIndex];
		if (!dictionaryEntry || dictionaryEntry.type !== 'term') return;
		const { term, reading } = dictionaryEntry.headwords[headwordIndex] ?? dictionaryEntry.headwords[0];
		const key = `${term}\u0000${reading}`;
		this.stopAudio();

		// With audio sources set in MacPopup, the first audio they have, as in Yomitan.
		const sources = getAudioSources(getSettings());
		if (sources.length > 0) {
			let result = null;
			this.setProgress(true);
			try {
				for (const source of sources) {
					result = await getAudio(source, term, reading, null);
					if (result !== null) break;
				}
			} finally {
				this.setProgress(false);
			}
			this.updateAudioMenus(term, reading);
			this.setAudioAvailable(entryIndex, result !== null);
			if (content !== this.content) return;
			if (result === null) {
				this.playFallbackSound();
				return;
			}
			this.stopAudio();
			this.audio = startAudio(result.audio, this.volume, (e) => log('Audio playback failed', e));
			return;
		}

		if (!this.audioCache.has(key)) {
			this.setProgress(true);
			try {
				// The API only fetches audio for the first headword of each entry.
				await this.fetchAudio(content.query, entryIndex + 1);
				if (!this.audioCache.has(key)) await this.fetchAudio(term, 1);
			} catch (e) {
				log('Failed to fetch audio', e);
			} finally {
				this.setProgress(false);
			}
			if (!this.audioCache.has(key)) this.audioCache.set(key, null);
			if (this.audioCache.size > 500) this.audioCache.delete(this.audioCache.keys().next().value);
		}

		const media = this.audioCache.get(key);
		this.setAudioAvailable(entryIndex, Boolean(media));
		if (content !== this.content) return;
		if (!media) {
			this.playFallbackSound();
			return;
		}
		this.audio = new Audio(`data:${media.mediaType || 'audio/mpeg'};base64,${media.content}`);
		this.audio.volume = this.volume;
		this.audio.play().catch((e) => log('Audio playback failed', e));
	}

	/** Marks the entry's play buttons with a cross when no audio was found. */
	setAudioAvailable(entryIndex, available) {
		for (const button of this.entryNodes[entryIndex]?.querySelectorAll('.action-button[data-action=play-audio]') ?? []) {
			const badge = button.querySelector('.action-button-badge');
			if (!badge) continue;
			if (available) {
				badge.hidden = true;
				delete badge.dataset.icon;
			} else {
				badge.hidden = false;
				badge.dataset.icon = 'cross';
				button.title = 'Audio unavailable';
			}
		}
	}

	// Audio source menu (right-click on a play button), as in Yomitan's DisplayAudio.

	getHeadword(entryIndex, headwordIndex) {
		const dictionaryEntry = this.content?.dictionaryEntries[entryIndex];
		if (!dictionaryEntry || dictionaryEntry.type !== 'term') return null;
		return dictionaryEntry.headwords[headwordIndex] ?? dictionaryEntry.headwords[0] ?? null;
	}

	showAudioMenu(button, entryIndex, headwordIndex) {
		const headword = this.getHeadword(entryIndex, headwordIndex);
		if (headword === null) return;
		const { term, reading } = headword;
		const sources = getAudioSources(getSettings());
		const container = this.generator.instantiateTemplate('audio-button-popup-menu');
		container.dataset.term = term;
		container.dataset.reading = reading;
		document.querySelector('#popup-menus').append(container);
		const menu = new PopupMenu(button, container);
		this.renderAudioMenu(menu, sources, term, reading);
		this.openAudioMenus.add(menu);
		menu.on('close', () => this.openAudioMenus.delete(menu));
		menu.prepare();
		roundMenuPosition(menu);
		// Asks every source which audio it has, so the menu lists each voice.
		for (const source of sources) {
			void loadInfoList(source, term, reading).then(() => this.updateAudioMenus(term, reading));
		}
	}

	/** Closes the audio source menus, e.g. when the popup hides or shows other content. */
	closeAudioMenus() {
		for (const menu of [...this.openAudioMenus]) menu.close(false);
		this.openAudioMenus.clear();
	}

	updateAudioMenus(term, reading) {
		const sources = getAudioSources(getSettings());
		for (const menu of this.openAudioMenus) {
			const { dataset } = menu.containerNode;
			if (menu.isClosed || dataset.term !== term || dataset.reading !== reading) continue;
			this.renderAudioMenu(menu, sources, term, reading);
			menu.updateMenuItems();
			menu.updatePosition();
			roundMenuPosition(menu);
		}
	}

	renderAudioMenu(menu, sources, term, reading) {
		const body = menu.bodyNode;
		body.replaceChildren();
		let showIcons = false;
		const primary = this.primaryCardAudio.get(`${term}\u0000${reading}`) ?? null;
		for (const source of sources) {
			const items = getLoadedInfoList(source, term, reading);
			const entries =
				items === null
					? [{ valid: null, subIndex: null, name: null }]
					: items.length === 0
						? [{ valid: false, subIndex: null, name: null }]
						: items.map(({ info, valid }, i) => ({ valid, subIndex: i, name: typeof info.name === 'string' ? info.name : null }));
			for (const [i, { valid, subIndex, name: subName }] of entries.entries()) {
				const node = this.generator.instantiateTemplate('audio-button-popup-menu-item');
				let label = source.name;
				if (!source.nameUnique) {
					label = `${label} ${source.nameIndex + 1}`;
					if (entries.length > 1) label = `${label} -`;
				}
				if (entries.length > 1) label = `${label} ${i + 1}`;
				if (subName) label += `: ${subName}`;
				node.querySelector('.popup-menu-item-audio-button .popup-menu-item-label').textContent = label;
				node.querySelector('.popup-menu-item-set-primary-audio-button').hidden = !source.downloadable;
				if (valid !== null) {
					node.querySelector('.popup-menu-item-audio-button .popup-menu-item-icon').dataset.icon = valid ? 'checkmark' : 'cross';
					showIcons = true;
				}
				node.dataset.index = `${source.index}`;
				if (subIndex !== null) node.dataset.subIndex = `${subIndex}`;
				node.dataset.valid = `${valid}`;
				node.dataset.sourceInOptions = 'true';
				node.dataset.downloadable = `${source.downloadable}`;
				node.dataset.isPrimaryCardAudio = `${primary !== null && primary.sourceIndex === source.index && primary.subIndex === subIndex}`;
				body.append(node);
			}
		}
		if (sources.length === 0) {
			const node = this.generator.instantiateTemplate('audio-button-popup-menu-item');
			const button = node.querySelector('.popup-menu-item-audio-button');
			button.disabled = true;
			button.querySelector('.popup-menu-item-label').textContent = 'No audio sources. Copy them with Settings → Import → Yomitan Settings.';
			node.querySelector('.popup-menu-item-set-primary-audio-button').hidden = true;
			body.append(node);
		}
		menu.containerNode.dataset.showIcons = `${showIcons}`;
	}

	onAudioMenuClose(e, entryIndex, headwordIndex) {
		const { action, item, menu, shiftKey } = e.detail;
		const group = item?.closest('.popup-menu-item-group');
		if (!group) return;
		const source = getAudioSources(getSettings())[Number.parseInt(group.dataset.index, 10)];
		if (!source) return;
		const subIndex = group.dataset.subIndex === undefined ? null : Number.parseInt(group.dataset.subIndex, 10);
		switch (action) {
			case 'playAudioFromSource':
				// Shift-click keeps the menu open.
				if (shiftKey) e.preventDefault();
				void this.playAudioFromSource(entryIndex, headwordIndex, source, subIndex);
				break;
			case 'setPrimaryAudio':
				e.preventDefault();
				void this.setPrimaryAudio(entryIndex, headwordIndex, source, subIndex, true);
				if (!menu.isClosed) this.updateAudioMenus(...this.getTermReading(entryIndex, headwordIndex));
				break;
		}
	}

	getTermReading(entryIndex, headwordIndex) {
		const { term, reading } = this.getHeadword(entryIndex, headwordIndex) ?? {};
		return [term, reading];
	}

	async playAudioFromSource(entryIndex, headwordIndex, source, subIndex) {
		const headword = this.getHeadword(entryIndex, headwordIndex);
		if (headword === null) return;
		const { term, reading } = headword;
		const content = this.content;
		this.stopAudio();
		this.setProgress(true);
		let result;
		try {
			result = await getAudio(source, term, reading, subIndex);
		} finally {
			this.setProgress(false);
		}
		this.updateAudioMenus(term, reading);
		if (content !== this.content) return;
		if (result === null) {
			this.playFallbackSound();
			return;
		}
		this.stopAudio();
		this.audio = startAudio(result.audio, this.volume, (e) => log('Audio playback failed', e));
		// As in Yomitan, the audio played from the menu is used for Anki cards.
		if (source.downloadable) await this.setPrimaryAudio(entryIndex, headwordIndex, source, result.subIndex, false);
	}

	async setPrimaryAudio(entryIndex, headwordIndex, source, subIndex, canToggleOff) {
		if (!source.downloadable) return;
		const headword = this.getHeadword(entryIndex, headwordIndex);
		if (headword === null) return;
		const key = `${headword.term}\u0000${headword.reading}`;
		const current = this.primaryCardAudio.get(key);
		if (canToggleOff && current && current.sourceIndex === source.index && current.subIndex === subIndex) {
			this.primaryCardAudio.delete(key);
			return;
		}
		this.primaryCardAudio.set(key, { sourceIndex: source.index, subIndex, source });
	}

	/** The audio chosen for Anki cards for an entry's first headword (the one whose audio the API adds). */
	async getCardAudioOverride(entryIndex) {
		const headword = this.getHeadword(entryIndex, 0);
		if (headword === null) return null;
		const chosen = this.primaryCardAudio.get(`${headword.term}\u0000${headword.reading}`);
		if (!chosen) return null;
		// Yomitan's "Idle download timeout" for audio added to cards.
		const { ankiDownloadTimeout } = getSettings();
		const timeout = Number.isFinite(ankiDownloadTimeout) && ankiDownloadTimeout > 0 ? ankiDownloadTimeout : null;
		const result = await getAudio(chosen.source, headword.term, headword.reading, chosen.subIndex, timeout);
		if (result === null || result.audio.type !== 'data') return null;
		return { term: headword.term, reading: headword.reading, data: result.audio.data, contentType: result.audio.contentType };
	}

	// Anki

	async updateAnki(token) {
		const settings = getSettings();
		const content = this.content;
		if (!settings.ankiEnabled || content.dictionaryEntries.length === 0) return;

		let details;
		try {
			const cardFormats = await overlay().getCardFormats();
			const cardFormatIndices = cardFormats.map((format, i) => (format.type === content.type ? i : -1)).filter((i) => i >= 0);
			if (cardFormatIndices.length === 0 || token !== this.renderToken) return;
			if (settings.checkForDuplicates && settings.ankiNoteDupeCheckFirst) {
				await this.showDuplicateIndicators(token, content, cardFormats, cardFormatIndices);
			}
			const notes = await buildFirstFieldNotes(content, cardFormats, cardFormatIndices, () => token !== this.renderToken);
			if (notes === null) return;
			let noteIds;
			if (settings.checkForDuplicates) {
				noteIds = await findNoteIds(notes.map(({ note }) => note));
			} else {
				await ankiInvoke('version');
				noteIds = notes.map(() => []);
			}
			this.cardFormats = cardFormats;
			details = notes.map((note, i) => ({
				...note,
				noteIds: noteIds[i],
				noteInfos: [],
				canAdd: (Object.values(note.note.fields)[0] ?? '').length > 0,
			}));
			if (this.isAdditionalInfoEnabled()) await this.addNoteInfos(details);
		} catch (e) {
			// Like Yomitan, the note buttons stay hidden when Anki can't be reached.
			log('Anki unavailable:', e);
			if (token === this.renderToken) this.removeDuplicateIndicators();
			return;
		}
		if (token !== this.renderToken) return;
		this.removeDuplicateIndicators();
		for (const detail of details) this.createNoteButtons(detail);
	}

	/** Whether the tags, flags and card states of existing notes are shown, as Yomitan's DisplayAnki._isAdditionalInfoEnabled. */
	isAdditionalInfoEnabled() {
		const settings = getSettings();
		return settings.ankiDisplayTagsAndFlags !== 'never' || settings.duplicateBehavior === 'overwrite';
	}

	async addNoteInfos(details) {
		const noteIds = [...new Set(details.flatMap((detail) => detail.noteIds))];
		try {
			const infos = await getNoteInfos(noteIds);
			const byId = new Map(noteIds.map((id, i) => [id, infos[i] ?? null]));
			for (const detail of details) detail.noteInfos = detail.noteIds.map((id) => byId.get(id) ?? null);
		} catch (e) {
			log('Failed to get Anki note info:', e);
		}
	}

	/**
	 * "Prioritize Anki note duplicate checks before note creation": checks for duplicates by the term alone
	 * and shows disabled buttons from that until the notes are rendered, as Yomitan's DisplayAnki._quickDupeCheck.
	 */
	async showDuplicateIndicators(token, content, cardFormats, cardFormatIndices) {
		const notes = [];
		const targets = [];
		content.dictionaryEntries.forEach((dictionaryEntry, entryIndex) => {
			const value = dictionaryEntry.type === 'kanji' ? dictionaryEntry.character : (dictionaryEntry.headwords?.[0]?.term ?? '');
			for (const cardFormatIndex of cardFormatIndices) {
				const cardFormat = cardFormats[cardFormatIndex];
				const [name] = Object.keys(cardFormat.fields);
				if (!name) continue;
				notes.push({ deckName: cardFormat.deck, modelName: cardFormat.model, fields: { [name]: value }, options: { duplicateScope: getSettings().duplicateScope } });
				targets.push({ entryIndex, cardFormat, cardFormatIndex });
			}
		});
		const noteIds = await findNoteIds(notes);
		if (token !== this.renderToken) return;
		const behavior = getSettings().duplicateBehavior;
		targets.forEach(({ entryIndex, cardFormat, cardFormatIndex }, i) => {
			const container = this.entryNodes[entryIndex]?.querySelector('.note-actions-container');
			if (!container) return;
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'action-button duplicate-indicator';
			button.dataset.cardFormatIndex = `${cardFormatIndex}`;
			button.disabled = true;
			button.style.opacity = '50%';
			button.title = 'Creating Anki notes...';
			const icon = document.createElement('span');
			icon.className = 'action-icon icon color-icon';
			const duplicate = behavior !== 'prevent' && noteIds[i].length > 0;
			icon.dataset.icon = duplicate ? `${behavior === 'overwrite' ? 'overwrite' : 'add-duplicate'}-${cardFormat.icon}` : cardFormat.icon;
			button.append(icon);
			container.append(button);
		});
	}

	removeDuplicateIndicators() {
		for (const node of this.container.querySelectorAll('.duplicate-indicator')) node.remove();
	}

	createNoteButtons(detail) {
		const { entryIndex, cardFormatIndex, noteIds, canAdd } = detail;
		const container = this.entryNodes[entryIndex]?.querySelector('.note-actions-container');
		if (!container) return;
		const cardFormat = this.cardFormats[cardFormatIndex];
		this.noteDetails.set(`${entryIndex}:${cardFormatIndex}`, detail);

		const group = this.generator.instantiateTemplate('action-button-container');
		group.dataset.cardFormatIndex = `${cardFormatIndex}`;
		const button = group.querySelector('.action-button');
		button.title = `Add ${cardFormat.name} note`;
		button.dataset.cardFormatIndex = `${cardFormatIndex}`;
		delete button.dataset.hotkey;
		button.querySelector('.action-icon').dataset.icon = cardFormat.icon;
		button.disabled = !canAdd;
		if (noteIds.length > 0) this.updateSaveButtonForDuplicateBehavior(button, cardFormat, noteIds);
		button.addEventListener('click', (e) => {
			e.preventDefault();
			void this.saveNote(entryIndex, cardFormatIndex, button);
		});
		container.appendChild(group);
		this.updateViewNoteButton(group, noteIds, detail.noteInfos);
		if (getSettings().ankiDisplayTagsAndFlags !== 'never') {
			this.addTagsIndicator(group, detail.noteInfos);
			this.addFlagsIndicator(group, detail.noteInfos);
		}
	}

	/** Yomitan's "Show card tags and flags": a button listing the tags of the existing notes. */
	addTagsIndicator(group, noteInfos) {
		const settings = getSettings();
		const tags = new Set(noteInfos.flatMap((info) => info?.tags ?? []));
		if (settings.ankiDisplayTagsAndFlags === 'non-standard') {
			for (const tag of splitTags(settings.ankiTags)) tags.delete(tag);
		} else if (settings.ankiDisplayTagsAndFlags === 'custom') {
			const targetTags = new Set(splitTags(settings.ankiTargetTags));
			for (const tag of [...tags]) if (!targetTags.has(tag)) tags.delete(tag);
		}
		if (tags.size === 0) return;
		const button = this.generator.instantiateTemplate('note-action-button-view-tags');
		button.disabled = false;
		button.hidden = false;
		button.title = `Card tags: ${[...tags].join(', ')}`;
		button.addEventListener('click', (e) => {
			e.preventDefault();
			this.showMessageNotification('tags', button.title);
		});
		group.appendChild(button);
	}

	/** A button showing the flags of the existing notes' cards in their colors. */
	addFlagsIndicator(group, noteInfos) {
		const flags = new Set(
			noteInfos.flatMap((info) => info?.cardsInfo ?? []).map(({ flags: flag }) => flagNames[flag]).filter((name) => name !== undefined),
		);
		if (flags.size === 0) return;
		const button = this.generator.instantiateTemplate('note-action-button-view-flags');
		button.disabled = false;
		button.hidden = false;
		button.title = `Card flags: ${[...flags].join(', ')}`;
		const slice = 100 / flags.size;
		const stops = [...flags].flatMap((flag, i) => [`${flagColors[flag]} ${i * slice}%`, `${flagColors[flag]} ${(i + 1) * slice}%`]);
		button.querySelector('.action-icon').style.background = `linear-gradient(to right, ${stops.join(', ')})`;
		button.addEventListener('click', (e) => {
			e.preventDefault();
			this.showMessageNotification('flags', button.title);
		});
		group.appendChild(button);
	}

	updateSaveButtonForDuplicateBehavior(button, cardFormat, noteIds) {
		const behavior = getSettings().duplicateBehavior;
		if (behavior === 'prevent') {
			button.disabled = true;
			button.title = 'Duplicate notes are disabled';
			return;
		}
		const verb = behavior === 'overwrite' ? 'Overwrite' : 'Add duplicate';
		const iconPrefix = behavior === 'overwrite' ? 'overwrite' : 'add-duplicate';
		if (behavior === 'overwrite') {
			button.dataset.overwrite = 'true';
			if (noteIds.length === 0) button.disabled = true;
		} else {
			delete button.dataset.overwrite;
		}
		button.title = `${verb} ${cardFormat.name} note`;
		button.querySelector('.action-icon').dataset.icon = `${iconPrefix}-${cardFormat.icon}`;
	}

	updateViewNoteButton(group, noteIds, noteInfos = []) {
		const previous = group.querySelector('.action-button[data-action=view-note]');
		if (noteIds.length === 0) {
			previous?.remove();
			return;
		}
		const button = this.generator.instantiateTemplate('note-action-button-view-note');
		button.disabled = false;
		button.hidden = false;
		delete button.dataset.hotkey;
		button.dataset.noteIds = noteIds.join(' ');
		// With note info, the icon shows how far the cards are, as in Yomitan.
		if (this.isAdditionalInfoEnabled() && noteInfos.length > 0) {
			const state = getCardState(noteInfos.flatMap((info) => info?.cardsInfo.map(({ cardState }) => cardState) ?? []));
			button.querySelector('.icon[data-icon^="view-note"]').dataset.icon = state === 'new' ? 'view-note' : `view-note-${state}`;
			button.title = `View added note (${state})`;
		}
		const badge = button.querySelector('.action-button-badge');
		if (noteIds.length > 1) {
			badge.dataset.icon = 'plus-thick';
			badge.hidden = false;
		} else {
			badge.hidden = true;
		}
		button.addEventListener('click', (e) => {
			e.preventDefault();
			void this.viewNotes(noteIds);
		});
		// In place of the previous one, before the tags and flags.
		if (previous) previous.replaceWith(button);
		else group.appendChild(button);
	}

	async viewNotes(noteIds) {
		try {
			if (getSettings().noteGuiMode === 'edit' && noteIds.length === 1) {
				await ankiInvoke('guiEditNote', { note: noteIds[0] });
			} else {
				await ankiInvoke('guiBrowse', { query: `nid:${noteIds.join(',')}` });
			}
		} catch (e) {
			this.showErrorNotification([e]);
		}
	}

	async createNote(entryIndex, cardFormatIndex) {
		const selectionText = window.getSelection()?.toString() ?? '';
		const content = this.content;
		const cardFormat = this.cardFormats[cardFormatIndex];
		const audioOverride = await this.getCardAudioOverride(entryIndex);
		return buildNote({ content, entryIndex, cardFormat, selectionText, audioOverride });
	}

	async saveNote(entryIndex, cardFormatIndex, button) {
		if (button.disabled) return;
		const content = this.content;
		const cardFormat = this.cardFormats[cardFormatIndex];
		const detail = this.noteDetails.get(`${entryIndex}:${cardFormatIndex}`);
		const settings = getSettings();
		const behavior = settings.duplicateBehavior;
		const errors = [];
		button.disabled = true;
		setTimeout(() => {
			if (behavior !== 'prevent' || errors.length > 0) button.disabled = false;
		}, 2500);
		this.notifications.error?.close(true);
		this.setProgress(true);
		try {
			const { note, media } = await this.createNote(entryIndex, cardFormatIndex);
			await storeMedia(media);
			if (button.dataset.overwrite) {
				await overwriteNote(detail.noteIds[0], note, cardFormat);
			} else {
				const noteId = await ankiInvoke('addNote', { note });
				if (noteId === null) throw new Error('Note could not be added');
				if (settings.ankiSuspendNewCards) {
					await suspendCardsForNote(noteId).catch((e) => errors.push(e instanceof Error ? e : new Error(`${e}`)));
				}
				detail.noteIds = [...detail.noteIds, noteId];
				// The new note's cards are new, or suspended.
				detail.noteInfos = [...(detail.noteInfos ?? []), { noteId, tags: [], cardsInfo: [{ flags: 0, cardState: settings.ankiSuspendNewCards ? -1 : 0 }] }];
				this.updateSaveButtonForDuplicateBehavior(button, cardFormat, detail.noteIds);
				this.updateViewNoteButton(button.closest('.action-button-container'), detail.noteIds, detail.noteInfos);
				if (settings.ankiForceSync) {
					await ankiInvoke('sync').catch((e) => errors.push(e instanceof Error ? e : new Error(`${e}`)));
				}
			}
		} catch (e) {
			errors.push(e instanceof Error ? e : new Error(`${e}`));
		} finally {
			this.setProgress(false);
		}
		if (errors.length > 0) this.showErrorNotification(errors);
	}

	/**
	 * Marks the element under the pointer and its ancestors, as :hover would. x is null when the pointer
	 * is elsewhere. Returns the cursor to show there.
	 */
	setPointerHover(x, y) {
		const hovered = new Set();
		for (let element = x === null ? null : document.elementFromPoint(x, y); element; element = element.parentElement) {
			hovered.add(element);
		}
		for (const element of this.pointerHovered) {
			if (!hovered.has(element)) element.classList.remove('pointer-hover');
		}
		for (const element of hovered) {
			if (!this.pointerHovered.has(element)) element.classList.add('pointer-hover');
		}
		this.pointerHovered = hovered;
		return x === null ? null : cursorAt(document, x, y);
	}

	// Nested scanning; pointer coordinates come from the overlay, relative to this frame.

	/** @param {boolean} mayScan False when the pointer rests and "Scan without mouse move" is off. */
	onPointer(x, y, mods, mayScan) {
		const settings = getSettings();
		clearTimeout(this.scanTimer);
		if (!mayScan) return;
		// Yomitan's "Maximum number of child popups".
		if (this.depth >= settings.popupNestingMaxDepth) return;
		const input = matchScanInput(settings.popupScanModifier, settings.popupScanInputs, mods);
		if (input === null) return;
		const element = document.elementFromPoint(x, y);
		if (!element || element.closest('.scan-disable, button, #content-sidebar, .frame-resizer-container, .footer-notification')) return;
		// Headwords only with Yomitan's "Enable scanning of popup expressions".
		if (!settings.popupScanExpressions && element.closest('.source-text')) return;
		if (input.passive) {
			this.scanTimer = setTimeout(() => void this.scanAt(x, y, input), settings.scanDelay);
		} else {
			void this.scanAt(x, y, input);
		}
	}

	/** @param {{searchTerms: boolean, searchKanji: boolean}} [lookup] What the scan input looks up. */
	async scanAt(x, y, lookup = undefined) {
		const source = getTextSourceFromPoint(x, y);
		if (!source) return;
		if (this.scanSource !== null && this.scanSource.hasSameStart(source)) return;
		this.scanSource = source;
		const token = ++this.scanToken;
		let result;
		try {
			result = await searchTextSource(source, lookup);
		} catch (e) {
			log('Lookup failed', e);
			return;
		}
		if (token !== this.scanToken || result === null) return;
		setHighlight(source);
		const rects = [...source.getRects()].map(({ left, top, right, bottom }) => ({ left, top, right, bottom }));
		overlay().showPopup(this.depth + 1, { ...result, documentTitle: this.content?.documentTitle ?? '' }, rects, this.depth);
	}

	clearScan() {
		clearTimeout(this.scanTimer);
		this.scanSource = null;
		this.scanToken++;
		setHighlight(null);
	}

	// The mouse wheel, as in Yomitan's Display: with Option it goes through the entries, with Shift through
	// the history.
	onWheel(e) {
		if (e.altKey) {
			if (e.deltaY !== 0) {
				this.focusEntry(this.index + (e.deltaY > 0 ? 1 : -1), 0, true);
				e.preventDefault();
			}
		} else if (e.shiftKey) {
			const delta = -e.deltaX || e.deltaY;
			if (delta !== 0) {
				this.navigate(delta > 0 ? -1 : 1);
				e.preventDefault();
				e.stopPropagation();
			}
		}
	}

	// Yomitan's "Search terms when clicking text from the results list": a click on a definition looks the
	// word up in this popup, and the history buttons go back to the previous results.
	async searchAtClick(e) {
		if (!getSettings().popupSearchOnClick || !(e.target instanceof Element)) return;
		if (!e.target.closest('.click-scannable') || e.target.closest('.scan-disable, a, button')) return;
		if (window.getSelection()?.isCollapsed === false) return;
		const source = getTextSourceFromPoint(e.clientX, e.clientY);
		if (!source) return;
		let result;
		try {
			result = await searchTextSource(source);
		} catch (error) {
			log('Lookup failed', error);
			return;
		}
		if (result === null) return;
		await this.setContent({ ...result, documentTitle: this.content?.documentTitle ?? '' }, 'new');
	}

	// Keyboard shortcuts (see overlay.js), as Yomitan's Display hotkey actions.

	runHotkey(action, argument) {
		const number = Number.parseInt(argument, 10);
		const count = Number.isFinite(number) ? number : 1;
		const cardFormatIndex = Number.isFinite(number) ? number : 0;
		const entry = this.entryNodes[this.index];
		switch (action) {
			case 'close':
				overlay().closePopup(this.depth);
				break;
			case 'nextEntry':
				this.focusEntry(this.index + count, 0, true);
				break;
			case 'previousEntry':
				this.focusEntry(this.index - count, 0, true);
				break;
			case 'firstEntry':
				this.focusEntry(0, 0, true);
				break;
			case 'lastEntry':
				this.focusEntry(this.entryNodes.length - 1, 0, true);
				break;
			case 'nextEntryDifferentDictionary':
				this.focusEntryWithDifferentDictionary(1);
				break;
			case 'previousEntryDifferentDictionary':
				this.focusEntryWithDifferentDictionary(-1);
				break;
			case 'historyBackward':
				this.navigate(-1);
				break;
			case 'historyForward':
				this.navigate(1);
				break;
			case 'addNote':
				entry?.querySelector(`.action-button[data-action=save-note][data-card-format-index="${cardFormatIndex}"]`)?.click();
				break;
			case 'viewNotes':
				entry?.querySelector(`.action-button-container[data-card-format-index="${cardFormatIndex}"] .action-button[data-action=view-note]`)?.click();
				break;
			case 'playAudio':
				void this.playAudio(this.index, 0);
				break;
			case 'playAudioFromSource':
				void this.playAudioFromSourceType(argument);
				break;
			case 'copyHostSelection':
				void this.copySelection();
				break;
		}
	}

	/** Makes an entry the current one and scrolls to it, or to one of its definitions, as Yomitan's Display._focusEntry. */
	focusEntry(index, definitionIndex, smooth) {
		if (this.entryNodes.length === 0) return;
		index = Math.max(Math.min(index, this.entryNodes.length - 1), 0);
		this.setCurrentEntry(index);
		let node = this.entryNodes[index];
		if (definitionIndex > 0) {
			const definitionNodes = node.querySelectorAll('.definition-item');
			if (definitionIndex < definitionNodes.length) node = definitionNodes[definitionIndex];
		}
		const body = document.querySelector('#content-body');
		const top = index === 0 && definitionIndex <= 0 ? 0 : node.getBoundingClientRect().top - body.getBoundingClientRect().top;
		document.querySelector('#content-scroll').scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' });
	}

	/** Goes to the next (sign 1) or previous (-1) definition from another dictionary, as Yomitan's Display._focusEntryWithDifferentDictionary. */
	focusEntryWithDifferentDictionary(sign) {
		const entries = this.content?.dictionaryEntries ?? [];
		const count = Math.min(entries.length, this.entryNodes.length);
		const index = this.index;
		if (index < 0 || index >= count || entries[index].type !== 'term') return;
		const visibleDefinitionIndex = this.getVisibleDefinitionIndex(index, sign);
		if (visibleDefinitionIndex === null) return;
		const { dictionary } = entries[index].definitions[visibleDefinitionIndex];
		for (let i = index; i >= 0 && i < count; i += sign) {
			if (entries[i].type !== 'term') continue;
			const { definitions } = entries[i];
			for (let j = i === index ? visibleDefinitionIndex + sign : sign > 0 ? 0 : definitions.length - 1; j >= 0 && j < definitions.length; j += sign) {
				if (definitions[j].dictionary !== dictionary) {
					this.focusEntry(i, j, true);
					return;
				}
			}
		}
	}

	/** The definition of an entry most in view, as Yomitan's Display._getDictionaryEntryVisibleDefinitionIndex. */
	getVisibleDefinitionIndex(index, sign) {
		const { top: scrollTop, bottom: scrollBottom } = document.querySelector('#content-scroll').getBoundingClientRect();
		const { definitions } = this.content.dictionaryEntries[index];
		const nodes = this.entryNodes[index].querySelectorAll('.definition-item');
		const count = Math.min(definitions.length, nodes.length);
		if (count <= 0) return null;
		let visibleIndex = null;
		let visibleCoverage = 0;
		for (let i = sign > 0 ? 0 : count - 1; i >= 0 && i < count; i += sign) {
			const { top, bottom } = nodes[i].getBoundingClientRect();
			if (bottom <= scrollTop || top >= scrollBottom) continue;
			const top2 = Math.max(scrollTop, Math.min(scrollBottom, top));
			const bottom2 = Math.max(scrollTop, Math.min(scrollBottom, bottom));
			const coverage = (bottom2 - top2) / (bottom - top);
			if (coverage >= visibleCoverage) {
				visibleCoverage = coverage;
				visibleIndex = i;
			}
		}
		return visibleIndex ?? (sign > 0 ? count - 1 : 0);
	}

	/** Plays the current entry's audio from a source type, the first source of that type set in MacPopup if any. */
	async playAudioFromSourceType(type) {
		const source = getAudioSources(getSettings()).find((item) => item.type === type) ?? getAudioSources({ audioSources: [{ type }] })[0];
		await this.playAudioFromSource(this.index, 0, source, null);
	}

	/** Copies the text selected in this popup, or else in the popup or text box it came from (Yomitan's copyHostSelection). */
	async copySelection() {
		const text = window.getSelection()?.toString() || overlay().getSelectionText(this.depth - 1);
		if (text) await nativeCall('copyText', { text });
	}

	// Frame resizer (bottom-right corner), as in Yomitan.

	setUpResizer() {
		const handle = document.querySelector('#frame-resizer-handle');
		let start = null;
		handle.addEventListener('pointerdown', (e) => {
			if (e.button !== 0) return;
			e.preventDefault();
			handle.setPointerCapture(e.pointerId);
			start = { x: e.screenX, y: e.screenY, ...overlay().getPopupSize(this.depth) };
		});
		handle.addEventListener('pointermove', (e) => {
			if (start === null) return;
			overlay().resizePopup(this.depth, start.width + e.screenX - start.x, start.height + e.screenY - start.y);
		});
		const end = (e) => {
			if (start === null) return;
			start = null;
			handle.releasePointerCapture(e.pointerId);
		};
		handle.addEventListener('pointerup', end);
		handle.addEventListener('pointercancel', end);
	}
}

window.macpopupPopup = new Popup();
