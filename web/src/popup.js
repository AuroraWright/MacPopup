// The Yomitan-style popup page, loaded in an iframe by the overlay (see overlay.js PopupManager).
// Entries are rendered by Yomitan's own DisplayGenerator, so the DOM matches Yomitan's popup
// and Yomitan custom CSS applies as-is. This replaces Yomitan's Display/DisplayAnki/DisplayAudio.
import './lib/chrome-shim.js';
import { DisplayContentManager } from '../../vendor/yomitan/ext/js/display/display-content-manager.js';
import { DisplayGenerator } from '../../vendor/yomitan/ext/js/display/display-generator.js';
import { DisplayNotification } from '../../vendor/yomitan/ext/js/display/display-notification.js';
import { ElementOverflowController } from '../../vendor/yomitan/ext/js/display/element-overflow-controller.js';
import { base64ToArrayBuffer } from '../../vendor/yomitan/ext/js/data/array-buffer-util.js';
import { addScopeToCss } from '../../vendor/yomitan/ext/js/core/utilities.js';
import { ankiInvoke, findNoteIds } from './lib/anki-connect.js';
import { buildFirstFieldNotes, buildNote, overwriteNote, storeMedia } from './lib/anki-notes.js';
import { log } from './lib/native.js';
import { matchScanInput, preventRightClickSelection } from './lib/scan-inputs.js';
import { adaptCssForWebKit } from './lib/webkit-css.js';
import { getTextSourceFromPoint, searchTextSource, setHighlight } from './lib/scanner.js';
import { getSettings, setLocalSettings } from './lib/settings.js';
import { ankiFields, kanjiEntries } from './lib/yomitan-api.js';

const overlay = () => window.parent.macpopupOverlay;

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
		this.dictionaryMediaPromise = null;
		this.notifications = { tag: null, inflection: null, error: null };
		this.scanTimer = null;
		this.scanSource = null;
		this.scanToken = 0;
		this.progressCount = 0;

		this.contentManager = new PopupContentManager(this);
		this.generator = new DisplayGenerator(this.contentManager, null);
		this.overflowController = new ElementOverflowController(this);
		this.container = document.querySelector('#dictionary-entries');
		this.footer = document.querySelector('#content-footer');
		this.progressIndicator = document.querySelector('#progress-indicator');
		this.ready = this.prepare();
	}

	get content() {
		return this.history[this.historyIndex] ?? null;
	}

	async prepare() {
		await this.generator.prepare();
		const data = document.documentElement.dataset;
		data.browser = 'safari';
		data.platform = 'mac';

		document.querySelector('#close-button').addEventListener('click', () => overlay().closePopup(this.depth));
		document.querySelector('#navigate-previous-button').addEventListener('click', () => this.navigate(-1));
		document.querySelector('#navigate-next-button').addEventListener('click', () => this.navigate(1));
		// Right-button scan inputs shouldn't open the context menu or select the word.
		preventRightClickSelection(document, getSettings);
		document.documentElement.addEventListener('click', (e) => {
			if (e.button !== 0) return;
			this.clearScan();
			overlay().closePopupsAbove(this.depth);
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
		data.language = 'ja';
		data.resultOutputMode = 'group';
		data.glossaryLayoutMode = settings.glossaryLayoutMode;
		data.compactTags = `${settings.compactTags}`;
		data.averageFrequency = `${settings.averageFrequency}`;
		data.frequencyDisplayMode = settings.frequencyDisplayMode;
		data.termDisplayMode = settings.termDisplayMode;
		data.enableSearchTags = 'false';
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
		await this.setContent({ ...result, sentence: content?.sentence ?? { text: query, offset: 0 }, documentTitle: content?.documentTitle ?? '' }, 'new');
	}

	async render() {
		const token = {};
		this.renderToken = token;
		const content = this.content;
		const settings = getSettings();

		this.stopAudio();
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
		this.overflowController.setOptions({
			dictionaries: [...dictionaries].map((name) => ({ name, definitionsCollapsible: settings.definitionsCollapsible })),
		});

		for (let i = 0; i < dictionaryEntries.length; ++i) {
			const dictionaryEntry = dictionaryEntries[i];
			const entry = dictionaryEntry.type === 'term'
				? this.generator.createTermEntry(dictionaryEntry, [])
				: this.generator.createKanjiEntry(dictionaryEntry, []);
			entry.dataset.index = `${i}`;
			this.addEntryEventListeners(entry);
			this.container.appendChild(entry);
			this.entryNodes.push(entry);
			this.overflowController.addElements(entry);
		}
		void this.contentManager.executeMediaRequests();
		this.setCurrentEntry(0);
		document.querySelector('#content-scroll').scrollTop = 0;

		if (settings.audioAutoPlay && content.type === 'term' && dictionaryEntries.length > 0) {
			void this.playAudio(0, 0);
		}
		await this.updateAnki(token);
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
			button.addEventListener('click', (e) => {
				e.preventDefault();
				const headword = button.closest('.headword');
				const headwordIndex = headword ? Number.parseInt(headword.dataset.index, 10) || 0 : 0;
				void this.playAudio(this.getEntryIndex(entry), headwordIndex);
			});
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
		const entryNode = this.entryNodes[entryIndex];
		for (const button of entryNode?.querySelectorAll('.action-button[data-action=play-audio]') ?? []) {
			const badge = button.querySelector('.action-button-badge');
			if (!badge) continue;
			if (media) {
				badge.hidden = true;
				delete badge.dataset.icon;
			} else {
				badge.hidden = false;
				badge.dataset.icon = 'cross';
				button.title = 'Audio unavailable';
			}
		}
		if (!media || content !== this.content) return;
		this.audio = new Audio(`data:${media.mediaType || 'audio/mpeg'};base64,${media.content}`);
		this.audio.play().catch((e) => log('Audio playback failed', e));
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
			const notes = await buildFirstFieldNotes(content, cardFormats, cardFormatIndices);
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
				canAdd: (Object.values(note.note.fields)[0] ?? '').length > 0,
			}));
		} catch (e) {
			// Like Yomitan, the note buttons stay hidden when Anki can't be reached.
			log('Anki unavailable:', e);
			return;
		}
		if (token !== this.renderToken) return;
		for (const detail of details) this.createNoteButtons(detail);
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
		this.updateViewNoteButton(group, noteIds);
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

	updateViewNoteButton(group, noteIds) {
		group.querySelector('.action-button[data-action=view-note]')?.remove();
		if (noteIds.length === 0) return;
		const button = this.generator.instantiateTemplate('note-action-button-view-note');
		button.disabled = false;
		button.hidden = false;
		delete button.dataset.hotkey;
		button.dataset.noteIds = noteIds.join(' ');
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
		group.appendChild(button);
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

	createNote(entryIndex, cardFormatIndex) {
		const selectionText = window.getSelection()?.toString() ?? '';
		return buildNote({ content: this.content, entryIndex, cardFormat: this.cardFormats[cardFormatIndex], selectionText });
	}

	async saveNote(entryIndex, cardFormatIndex, button) {
		if (button.disabled) return;
		const content = this.content;
		const cardFormat = this.cardFormats[cardFormatIndex];
		const detail = this.noteDetails.get(`${entryIndex}:${cardFormatIndex}`);
		const behavior = getSettings().duplicateBehavior;
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
				detail.noteIds = [...detail.noteIds, noteId];
				this.updateSaveButtonForDuplicateBehavior(button, cardFormat, detail.noteIds);
				this.updateViewNoteButton(button.closest('.action-button-container'), detail.noteIds);
			}
		} catch (e) {
			errors.push(e instanceof Error ? e : new Error(`${e}`));
		} finally {
			this.setProgress(false);
		}
		if (errors.length > 0) this.showErrorNotification(errors);
	}

	// Nested scanning; pointer coordinates come from the overlay, relative to this frame.

	onPointer(x, y, mods) {
		const settings = getSettings();
		clearTimeout(this.scanTimer);
		const input = matchScanInput(settings.popupScanModifier, settings.popupScanInputs, mods);
		if (input === null) return;
		const element = document.elementFromPoint(x, y);
		if (!element || element.closest('.scan-disable, button, #content-sidebar, .frame-resizer-container, .footer-notification')) return;
		if (input.passive) {
			this.scanTimer = setTimeout(() => void this.scanAt(x, y), settings.scanDelay);
		} else {
			void this.scanAt(x, y);
		}
	}

	async scanAt(x, y) {
		const source = getTextSourceFromPoint(x, y);
		if (!source) return;
		if (this.scanSource !== null && this.scanSource.hasSameStart(source)) return;
		this.scanSource = source;
		const token = ++this.scanToken;
		let result;
		try {
			result = await searchTextSource(source);
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
