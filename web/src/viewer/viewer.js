// The iOS app's reading page: a picture with MacPopup's invisible text layer over it (lib/ocr-layer.js), opened in
// Safari so the user's dictionary extension scans it. The app serves it from 127.0.0.1 while it runs; the service
// worker (sw.js) and the readings kept in the cache let pages open again once the app is suspended or quit.
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

/** A reading: /r/<id>/reading.json ({image: {width, height}, lines, engine, language, createdAt}) and its picture. */
async function showReading(id) {
	$('reading').hidden = false;
	$('boxes-toggle').hidden = false;
	const reading = await (await fetch(`/r/${id}/reading.json`)).json();
	const { width, height } = reading.image;
	const image = $('image');
	image.width = width;
	image.height = height;
	image.src = `/r/${id}/image`;
	const layer = $('ocr-layer');
	layer.style.width = `${width}px`;
	layer.style.height = `${height}px`;
	const lines = decodeLines(reading.lines);
	renderLines($('ocr-text'), lines);
	const fit = () => {
		const scale = Math.min(1, document.documentElement.clientWidth / width);
		$('stage').style.transform = `scale(${scale})`;
		$('frame').style.height = `${height * scale}px`;
	};
	fit();
	addEventListener('resize', fit);
	document.title = lines.length ? lineText(lines[0]).slice(0, 40) : 'Reading';
	$('status').textContent = `${formatDate(reading.createdAt)} · ${lines.length ? `${lines.length} lines` : 'no text found'}`;
	await image.decode().catch(() => {});
	// The first visit isn't the service worker's yet, so the page keeps its reading for later visits itself.
	try {
		const cache = await caches.open(CACHE);
		if (!(await cache.match(`/r/${id}/reading.json`))) await cache.addAll([`/r/${id}/reading.json`, `/r/${id}/image`]);
	} catch {}
}

/** Drops the kept copies of readings deleted in the app. */
async function forgetDeleted(readings) {
	const ids = new Set(readings.map(({ id }) => id));
	const cache = await caches.open(CACHE);
	for (const request of await cache.keys()) {
		const [kind, id] = new URL(request.url).pathname.split('/').slice(1);
		if (kind === 'r' && !ids.has(id)) await cache.delete(request);
	}
}

/** The readings: the app's list while it runs, else the ones this browser has kept. */
async function showIndex() {
	$('index').hidden = false;
	let readings;
	try {
		readings = await (await fetch('/readings.json')).json();
		forgetDeleted(readings).catch(() => {});
	} catch {
		const cache = await caches.open(CACHE);
		const ids = [...new Set((await cache.keys()).map((request) => new URL(request.url).pathname.split('/')[2]).filter(Boolean))];
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

const boxes = $('boxes');
boxes.checked = new URLSearchParams(location.search).has('boxes') || storageGet('macpopup-boxes') === '1';
$('ocr-layer').classList.toggle('show-boxes', boxes.checked);
boxes.addEventListener('change', () => {
	$('ocr-layer').classList.toggle('show-boxes', boxes.checked);
	storageSet('macpopup-boxes', boxes.checked ? '1' : '0');
});

const parts = location.pathname.split('/').filter(Boolean);
(parts[0] === 'r' && parts[1] ? showReading(parts[1]) : showIndex()).catch((error) => {
	$('status').textContent = `Couldn’t open this reading (${error.message})`;
});
navigator.serviceWorker?.register('/sw.js').catch(() => {});
