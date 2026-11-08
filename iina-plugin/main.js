// Each player window: sends its subtitle lines to global.js (and so to MacPopup) with their timing, and the file and
// streams that MacPopup takes their screenshot and sentence audio from.
const { mpv, event, global } = iina;

let number = 0;

/** The selected track of a type as a local file and its stream index for ffmpeg, or null (e.g. for streams). */
function selected(type) {
	const tracks = mpv.getNative('track-list') ?? [];
	const track = tracks.find((t) => t.type === type && t.selected && !t.image);
	if (!track || typeof track['ff-index'] !== 'number') return null;
	const path = track.external ? track['external-filename'] : mpv.getString('path');
	if (typeof path !== 'string' || !path.startsWith('/')) return null;
	return { file: path, stream: track['ff-index'] };
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
		player: {
			start: typeof start === 'number' ? start : null,
			end: typeof end === 'number' ? end : null,
			video: selected('video'),
			audio: selected('audio'),
		},
	});
});
