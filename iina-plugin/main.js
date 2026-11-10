// Each player window: sends its subtitle lines to global.js (and so to MacPopup) with their timing and where MacPopup
// can read their video and audio from, and answers MacPopup's requests for a line's DASH fragments or a dump of it from
// mpv's cache (see global.js).
const { mpv, event, global, file } = iina;

// Tells this window's lines, and MacPopup's requests for them, apart from other windows'.
const key = Math.random().toString(36).slice(2);
let number = 0;

/**
 * The cookies mpv sends to a URL from its cookies file (when its cookies option is on), as a Cookie header's value, or
 * null. The file has a cookie a line in Netscape's format: domain, subdomains, path, secure, expiry, name and value.
 */
function cookies(url) {
	const path = mpv.getFlag('cookies') ? mpv.getString('cookies-file') : '';
	const parts = /^(https?):\/\/([^/?#:]+)(?::\d+)?([^?#]*)/i.exec(url);
	if (!path || !parts) return null;
	let text = null;
	try {
		text = file.read(path);
	} catch (_) {
		return null;
	}
	const host = parts[2].toLowerCase();
	const now = Date.now() / 1000;
	const pairs = (text ?? '').split(/\r?\n/).flatMap((line) => {
		const fields = line.replace(/^#HttpOnly_/, '').split('\t');
		if (fields.length < 7 || fields[0].startsWith('#')) return [];
		const [domain, , cookiePath, secure, expiry, name, value] = fields;
		const bare = domain.replace(/^\./, '').toLowerCase();
		const sent = (host === bare || host.endsWith(`.${bare}`)) && (parts[3] || '/').startsWith(cookiePath)
			&& (secure !== 'TRUE' || parts[1].toLowerCase() === 'https') && !(Number(expiry) > 0 && Number(expiry) < now);
		return sent ? [`${name}=${value}`] : [];
	});
	return pairs.length ? pairs.join('; ') : null;
}

/**
 * mpv's request headers for a network stream (e.g. from IINA's yt-dlp plugin), as "Name: value" lines, with the
 * cookies it sends to the URL.
 */
function headers(url) {
	const fields = (mpv.getNative('http-header-fields') ?? []).filter((field) => typeof field === 'string');
	const has = (name) => fields.some((field) => field.toLowerCase().startsWith(`${name}:`));
	const userAgent = mpv.getString('user-agent');
	const referrer = mpv.getString('referrer');
	const cookie = cookies(url);
	if (userAgent && !has('user-agent')) fields.push(`User-Agent: ${userAgent}`);
	if (referrer && !has('referer')) fields.push(`Referer: ${referrer}`);
	if (cookie && !has('cookie')) fields.push(`Cookie: ${cookie}`);
	return fields;
}

/** The http proxy mpv uses (e.g. yt-dlp's, which IINA's yt-dlp plugin passes on as a stream option), or null. */
function proxy() {
	const options = mpv.getNative('stream-lavf-o');
	const value = (options && typeof options === 'object' ? options.http_proxy : null) || mpv.getString('http-proxy');
	return typeof value === 'string' && /^http:\/\//i.test(value) ? value : null;
}

/**
 * The entries of an mpv EDL ("edl://entry;entry..."), each a list of [name, value] params (null for a value without a
 * name), or null. A value can be escaped as "%<its length in bytes>%<value>".
 */
function parseEDL(edl) {
	// One character per UTF-8 byte, for the escapes' lengths.
	const text = unescape(encodeURIComponent(edl.slice('edl://'.length)));
	const decode = (value) => decodeURIComponent(escape(value));
	const entries = [];
	let params = [];
	let i = 0;
	while (i < text.length) {
		let name = null;
		const next = text.slice(i).search(/[=%,;\n]/);
		if (next > 0 && text[i + next] === '=') {
			name = decode(text.slice(i, i + next));
			i += next + 1;
		}
		let value;
		if (text[i] === '%') {
			const close = text.indexOf('%', i + 1);
			const length = Number(text.slice(i + 1, close));
			if (close < 0 || !Number.isInteger(length)) return null;
			value = text.slice(close + 1, close + 1 + length);
			i = close + 1 + length;
		} else {
			const end = text.slice(i).search(/[,;\n]/);
			value = end < 0 ? text.slice(i) : text.slice(i, i + end);
			i += value.length;
		}
		params.push([name, decode(value)]);
		if (text[i++] !== ',') {
			if (params.length > 1 || params[0][0] !== null || params[0][1] !== '') entries.push(params);
			params = [];
		}
	}
	if (params.length) entries.push(params);
	return entries;
}

let lastDash = { location: null, fragments: null };

/**
 * The fragments of a DASH track that IINA's yt-dlp plugin plays as an EDL ("!mp4_dash,init=<url>;<url>,length=
 * <seconds>;..."), with their times: {init, parts: [{url, start, length}]}; or null for another kind of EDL.
 */
function dashFragments(location) {
	if (lastDash.location === location) return lastDash.fragments;
	let entries = null;
	try {
		entries = parseEDL(location);
	} catch (_) {}
	let init = null;
	let time = 0;
	const parts = [];
	const http = (url) => /^https?:\/\//i.test(url);
	for (const [[name, value], ...params] of entries ?? []) {
		if (name !== null) {
			entries = null;
		} else if (value === '!mp4_dash') {
			init = params.find(([param]) => param === 'init')?.[1] ?? null;
		} else if (value.startsWith('!')) {
			// (Only what doesn't move the parts; e.g. not !new_stream, which starts another track.)
			if (!['!no_clip', '!no_chapters', '!track_meta', '!global_tags'].includes(value)) entries = null;
		} else {
			// (A part that starts later in its file, or without a length, can't be placed.)
			const length = Number(params.find(([param]) => param === 'length')?.[1]);
			if (!(length > 0) || !http(value) || params.some(([param]) => param === 'start')) entries = null;
			parts.push({ url: value, start: time, length });
			time += length;
		}
		if (!entries) break;
	}
	const fragments = entries && init && http(init) && parts.length ? { init, parts } : null;
	lastDash = { location, fragments };
	return fragments;
}

/** The selected track of a type, and where mpv reads it from. */
function selected(type) {
	const tracks = mpv.getNative('track-list') ?? [];
	const track = tracks.find((t) => t.type === type && t.selected && !t.image);
	if (!track) return null;
	// stream-open-filename is what mpv plays, e.g. the media URL that yt-dlp found for a web page.
	const location = track.external ? track['external-filename'] : mpv.getString('stream-open-filename') || mpv.getString('path');
	return { track, location: typeof location === 'string' ? location : null };
}

/**
 * Where MacPopup reads the selected track of a type from, or null: a local file, or an http(s) stream that ffmpeg
 * can open (not DASH) and seek in (not a live stream: mpv reports a duration for one, of what has arrived so far), with
 * ffmpeg's stream index; DASH fragments, which MacPopup asks this window for; or else mpv's cache, which MacPopup has
 * this window dump the line from (only the tracks of the main stream are in it).
 */
function source(type) {
	const { track, location } = selected(type) ?? {};
	if (!track) return null;
	const stream = track['ff-index'];
	if (location && typeof stream === 'number') {
		if (location.startsWith('/')) return { file: location, stream };
		if (/^https?:\/\//i.test(location) && mpv.getFlag('seekable') && mpv.getString('file-format') !== 'dash') {
			return { url: location, stream, headers: headers(location), proxy: proxy() };
		}
	}
	if (location?.startsWith('edl://') && dashFragments(location)) return { fragments: key };
	return track.external ? null : { cache: key };
}

// IINA observes the properties of mpv.*.changed events as numbers, so sub-text's changes aren't reported:
// sub-start changes with each line instead.
event.on('mpv.sub-start.changed', () => {
	const text = mpv.getString('sub-text') ?? '';
	if (!text.trim()) return;
	const start = mpv.getNative('sub-start');
	const end = mpv.getNative('sub-end');
	number += 1;
	global.postMessage('line', {
		number,
		text,
		key,
		player: {
			start: typeof start === 'number' ? start : null,
			end: typeof end === 'number' ? end : null,
			video: source('video'),
			audio: source('audio'),
		},
	});
});

// The DASH fragments of a track that a time range is in, with the requests' headers and proxy.
global.onMessage('fragments', (request) => {
	if (request?.key !== key) return;
	// A reply posted while global.js's handler runs loses global.js's variables.
	setTimeout(() => {
		const location = selected(request.type)?.location;
		const fragments = location ? dashFragments(location) : null;
		const parts = (fragments?.parts ?? []).filter((part) => part.start < request.end && part.start + part.length > request.start);
		const reply = parts.length
			? { id: request.id, init: fragments.init, parts, headers: headers(fragments.init), proxy: proxy() }
			: { id: request.id, error: fragments ? 'The line is outside the video' : 'The video changed' };
		global.postMessage('reply', reply);
	}, 0);
});

// A time range of this window's stream, dumped from mpv's cache into the file MacPopup names. mpv's dump starts
// at the keyframe before the range, with its times starting at 0, and an empty or partial dump still "succeeds", so
// the range is checked against what's cached first; a line that's still playing in a live stream may not have arrived
// yet (and what has arrived becomes seekable a little later), so it waits for it a while.
global.onMessage('dump', (request) => {
	if (request?.key !== key) return;
	const waitUntil = Date.now() + 15000;
	const attempt = () => {
		const ranges = mpv.getNative('demuxer-cache-state')?.['seekable-ranges'] ?? [];
		const from = ranges.find((range) => range.start <= request.start && range.end > request.start);
		const ahead = !from && ranges.some((range) => range.start <= request.start);
		let reply;
		if (from && from.end >= request.end) {
			// (Without the file-system permission IINA ignores dump-cache, and it crashes on an argument that isn't a
			// string.)
			mpv.command('dump-cache', [String(request.start), String(request.end), String(request.file)]);
			reply = { id: request.id, file: request.file };
		} else if ((from || ahead) && Date.now() < waitUntil) {
			setTimeout(attempt, 250);
			return;
		} else {
			reply = { id: request.id, error: from || ahead ? 'The line didn’t reach IINA’s cache' : 'The line is no longer in IINA’s cache' };
		}
		global.postMessage('reply', reply);
	};
	// A reply posted while global.js's handler runs loses global.js's variables.
	setTimeout(attempt, 0);
});
