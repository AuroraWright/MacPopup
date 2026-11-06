// The reading page's service worker: pages open again after the iOS app that serves them is suspended or quit.
// Readings never change, so they come from the cache first. The page itself and the list of readings come from the
// app when it answers within a second (a suspended app's port takes connections without answering), else the cache.
const CACHE = 'macpopup-readings';
const SHELL = ['/viewer.html', '/viewer.js', '/viewer.css'];

self.addEventListener('install', (event) => {
	event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

async function fromApp(request) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), 1000);
	try {
		return await fetch(request, { signal: controller.signal });
	} finally {
		clearTimeout(timer);
	}
}

self.addEventListener('fetch', (event) => {
	const url = new URL(event.request.url);
	if (event.request.method !== 'GET' || url.origin !== location.origin) return;
	const parts = url.pathname.split('/').filter(Boolean);
	// Live readings' events stream from the app.
	if (url.pathname === '/live/events') return;
	if ((parts[0] === 'r' || parts[0] === 'l') && parts.length === 3) {
		event.respondWith((async () => {
			const cache = await caches.open(CACHE);
			const cached = await cache.match(url.pathname);
			if (cached) return cached;
			const response = await fetch(event.request);
			if (response.ok) await cache.put(url.pathname, response.clone());
			return response;
		})());
		return;
	}
	if (url.pathname === '/readings.json' || url.pathname === '/live.json') {
		// No cache: the page lists the kept readings itself when the app doesn't answer.
		event.respondWith(fromApp(event.request));
		return;
	}
	// Every page is the viewer (it reads the path).
	const key = SHELL.includes(url.pathname) ? url.pathname : '/viewer.html';
	event.respondWith((async () => {
		const cache = await caches.open(CACHE);
		try {
			const response = await fromApp(event.request);
			if (response.ok) await cache.put(key, response.clone());
			return response;
		} catch {
			return (await cache.match(key)) ?? new Response('MacPopup isn’t running.', { status: 503 });
		}
	})());
});
