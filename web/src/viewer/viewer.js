// The iOS app's reading page: a picture with MacPopup's invisible text layer over it (lib/ocr-layer.js), opened in
// Safari so the user's dictionary extension scans it. The app serves it from 127.0.0.1 while it runs; the service
// worker (sw.js) and the readings kept in the cache let pages open again once the app is suspended or quit. /live is
// continuous mode's page: its readings as they come, newest first.
import { decodeLines, lineText, renderLines } from '../lib/ocr-layer.js';

const CACHE = 'macpopup-readings';
const $ = (id) => document.getElementById(id);

function storageGet(key) {
	try { return localStorage.getItem(key); } catch { return null; }
}

function storageSet(key, value) {
	try { localStorage.setItem(key, value); } catch {}
}

function formatDate(time) {
	return new Date(time).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function element(tag, className) {
	const created = document.createElement(tag);
	if (className) created.className = className;
	return created;
}

/** Scales each reading's picture and text to the page's width. */
const fits = [];
addEventListener('resize', () => fits.forEach((fit) => fit()));

/**
 * Shows a reading ({image: {width, height}, lines, engine, language, createdAt}) in `container`, its picture at
 * `base`/image: the picture with the text layer, scaled together to the page's width. Returns its lines.
 */
function renderReading(container, base, reading) {
	const { width, height } = reading.image;
	const frame = element('div', 'frame');
	const stage = element('div', 'stage');
	const image = new Image(width, height);
	image.alt = '';
	image.src = `${base}/image`;
	const layer = element('div', 'ocr-layer');
	layer.style.width = `${width}px`;
	layer.style.height = `${height}px`;
	const text = element('div', 'ocr-text');
	layer.append(text);
	stage.append(image, layer);
	frame.append(stage);
	container.append(frame);
	// Laid out in the page and unscaled, since renderLines measures the glyphs.
	const lines = decodeLines(reading.lines);
	renderLines(text, lines);
	const fit = () => {
		const scale = Math.min(1, document.documentElement.clientWidth / width);
		stage.style.transform = `scale(${scale})`;
		frame.style.height = `${height * scale}px`;
	};
	fit();
	fits.push(fit);
	return { lines, image };
}

/** The first visit isn't the service worker's yet, so the page keeps the reading for later visits itself. */
async function keep(base) {
	try {
		const cache = await caches.open(CACHE);
		if (!(await cache.match(`${base}/reading.json`))) await cache.addAll([`${base}/reading.json`, `${base}/image`]);
	} catch {}
}

/**
 * Fetches a reading the app has just saved: Safari can open its page before the app, woken in the background, answers,
 * so it tries again for a while.
 */
async function fetchNew(url) {
	for (let attempt = 0; ; attempt++) {
		try {
			return await fetch(url);
		} catch (error) {
			if (attempt === 30) throw error;
			$('status').textContent = 'Waiting for MacPopup…';
			await new Promise((resolve) => setTimeout(resolve, 500));
		}
	}
}

/** A reading: /r/<id>/reading.json and its picture. */
async function showReading(id) {
	$('reading').hidden = false;
	$('boxes-toggle').hidden = false;
	const base = `/r/${id}`;
	const reading = await (await fetchNew(`${base}/reading.json`)).json();
	const { lines, image } = renderReading($('reading'), base, reading);
	document.title = lines.length ? lineText(lines[0]).slice(0, 40) : 'Reading';
	$('status').textContent = `${formatDate(reading.createdAt)} · ${lines.length ? `${lines.length} lines` : 'no text found'}`;
	await image.decode().catch(() => {});
	await keep(base);
}

/** Drops the kept copies of readings (`kind` r, or l for live ones) the app no longer has. */
async function forgetDeleted(kind, readings) {
	const ids = new Set(readings.map(({ id }) => id));
	const cache = await caches.open(CACHE);
	for (const request of await cache.keys()) {
		const [requestKind, id] = new URL(request.url).pathname.split('/').slice(1);
		if (requestKind === kind && !ids.has(id)) await cache.delete(request);
	}
}

/** The ids of the readings of a kind this browser has kept, newest first (ids are base-36 times). */
async function keptIds(kind) {
	const cache = await caches.open(CACHE);
	const ids = new Set((await cache.keys()).map((request) => new URL(request.url).pathname.split('/')).filter((parts) => parts[1] === kind).map((parts) => parts[2]));
	return [...ids].filter(Boolean).sort((a, b) => parseInt(b, 36) - parseInt(a, 36));
}

/** The readings: the app's list while it runs, else the ones this browser has kept. */
async function showIndex() {
	$('index').hidden = false;
	let readings;
	try {
		readings = await (await fetch('/readings.json')).json();
		forgetDeleted('r', readings).catch(() => {});
	} catch {
		const cache = await caches.open(CACHE);
		const ids = await keptIds('r');
		readings = await Promise.all(ids.map(async (id) => {
			const reading = await (await cache.match(`/r/${id}/reading.json`)).json();
			return { id, createdAt: reading.createdAt, text: decodeLines(reading.lines).map(lineText).join(' ') };
		}));
		readings.sort((a, b) => b.createdAt - a.createdAt);
		$('status').textContent = 'The app isn’t running: readings kept by Safari';
	}
	$('empty').hidden = readings.length > 0;
	$('readings').replaceChildren(...readings.map(({ id, createdAt, text }) => {
		const item = document.createElement('li');
		const link = document.createElement('a');
		link.href = `/r/${id}`;
		const thumbnail = document.createElement('img');
		thumbnail.src = `/r/${id}/image`;
		thumbnail.loading = 'lazy';
		thumbnail.alt = '';
		const body = document.createElement('div');
		const textElement = document.createElement('div');
		textElement.className = 'text';
		textElement.lang = 'ja';
		textElement.textContent = text || '—';
		const meta = document.createElement('div');
		meta.className = 'meta';
		meta.textContent = formatDate(createdAt);
		body.append(textElement, meta);
		link.append(thumbnail, body);
		item.append(link);
		return item;
	}));
}

/** The live readings shown, by id. */
const shownLive = new Set();
/** The newest reading's id first: live readings arrive in order, but the list and the events can overlap. */
let liveOrder = [];

/** Adds a live reading at its place in the list, keeping what the user is looking at where it is. */
async function addLive(id, isNew) {
	if (shownLive.has(id)) return;
	shownLive.add(id);
	liveOrder = [...liveOrder, id].sort((a, b) => parseInt(b, 36) - parseInt(a, 36));
	const next = liveOrder[liveOrder.indexOf(id) + 1];
	// In the list before its reading arrives, so that readings added meanwhile go around it.
	const article = element('article', isNew ? 'new' : '');
	article.dataset.id = id;
	const list = $('live-readings');
	list.insertBefore(article, (next && list.querySelector(`[data-id="${next}"]`)) || null);
	const base = `/l/${id}`;
	const reading = await (await fetch(`${base}/reading.json`)).json();
	if (!article.isConnected) return;
	// A reading added above the part of the list on screen would push it down.
	const above = scrollY > 0 && article.getBoundingClientRect().top < document.querySelector('header').offsetHeight;
	const meta = element('div', 'meta');
	meta.textContent = formatDate(reading.createdAt);
	article.append(meta);
	renderReading(article, base, reading);
	if (above) scrollBy(0, article.offsetHeight);
	$('live-empty').hidden = true;
	keep(base);
}

/** Catches up with the app's live readings (after loading, and when the page reconnects). */
async function syncLive() {
	const readings = await (await fetch('/live.json')).json();
	forgetDeleted('l', readings).catch(() => {});
	const ids = new Set(readings.map(({ id }) => id));
	for (const article of [...$('live-readings').children]) {
		if (!ids.has(article.dataset.id)) {
			shownLive.delete(article.dataset.id);
			liveOrder = liveOrder.filter((id) => id !== article.dataset.id);
			article.remove();
		}
	}
	// Oldest first, so that each one goes on top of the ones before it.
	for (const { id } of readings.slice(0, 100).reverse()) await addLive(id, false);
	$('live-empty').hidden = readings.length > 0;
}

/** Continuous mode's readings, updated as the app reads them (server-sent events), else the ones kept by Safari. */
async function showLive() {
	$('live').hidden = false;
	$('boxes-toggle').hidden = false;
	document.title = 'Live';
	try {
		await syncLive();
	} catch {
		for (const id of (await keptIds('l')).slice(0, 100).reverse()) await addLive(id, false).catch(() => {});
		$('live-empty').hidden = shownLive.size > 0;
	}
	const events = new EventSource('/live/events');
	events.addEventListener('open', () => {
		$('status').textContent = 'Reading paused while open';
		syncLive().catch(() => {});
	});
	// The screen broadcast sees this page too: while it's in front, the app doesn't read the screen (it pauses for as
	// long as this keeps telling it, so it reads again soon after Safari goes to the background).
	const reportVisible = () => {
		if (document.visibilityState === 'visible') fetch('/live.json?visible', { cache: 'no-store' }).catch(() => {});
	};
	reportVisible();
	setInterval(reportVisible, 1000);
	document.addEventListener('visibilitychange', reportVisible);
	events.addEventListener('error', () => {
		$('status').textContent = 'The app isn’t running: readings kept by Safari';
	});
	events.addEventListener('message', (event) => {
		addLive(JSON.parse(event.data).id, true).catch(() => {});
	});
}

const boxes = $('boxes');
boxes.checked = new URLSearchParams(location.search).has('boxes') || storageGet('macpopup-boxes') === '1';
document.body.classList.toggle('show-boxes', boxes.checked);
boxes.addEventListener('change', () => {
	document.body.classList.toggle('show-boxes', boxes.checked);
	storageSet('macpopup-boxes', boxes.checked ? '1' : '0');
});

const parts = location.pathname.split('/').filter(Boolean);
const page = parts[0] === 'live' ? showLive() : parts[0] === 'r' && parts[1] ? showReading(parts[1]) : showIndex();
page.catch((error) => {
	$('status').textContent = `Couldn’t open this page (${error.message})`;
});
navigator.serviceWorker?.register('/sw.js').catch(() => {});
