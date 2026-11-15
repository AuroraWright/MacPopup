// The debug log (Settings → General → Debug), for the overlay page and the popups.
import { nativeCall } from './native.js';
import { getSettings } from './settings.js';

/**
 * With Settings → General → Debug on, writes `record` to the debug log (debug.jsonl in Application Support/MacPopup;
 * see DebugLog.swift): each OCR reading and what was done with it, WebSocket lines, and events (logEvent).
 */
export function logDebug(record) {
	if (!getSettings().ocrShowBoxes) return;
	nativeCall('debugLog', { json: JSON.stringify({ time: new Date().toISOString(), ...record }) }).catch(() => {});
}

/**
 * What happens around the readings (controller focus, the pause and scan shortcut, held-back readings), and popups,
 * popup shortcuts, cards added, screenshots and messages shown.
 */
export function logEvent(event, fields = {}) {
	logDebug({ type: 'event', event, ...fields });
}
