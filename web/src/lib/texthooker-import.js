// Converts a texthooker-ui settings export into MacPopup settings.

/**
 * texthooker-ui exports settings as {currentSettings: {fontSize$: 24, ...}, ...}.
 * @param {object} currentSettings Used to skip values MacPopup doesn't know.
 * @returns {object} The MacPopup settings to save.
 */
export function importTexthookerSettings(json, currentSettings) {
	const data = JSON.parse(json);
	const source = data.currentSettings ?? data;
	const result = {};
	for (const [rawKey, value] of Object.entries(source)) {
		const key = rawKey.replace(/\$$/, '');
		if (!(key in currentSettings) || ['websocketUrls'].includes(key)) continue;
		if (typeof currentSettings[key] === 'number') {
			// Older texthooker-ui versions stored and exported some numeric settings (e.g. line padding) as strings.
			const number = typeof value === 'string' && value.trim() !== '' ? Number(value) : value;
			if (typeof number === 'number' && Number.isFinite(number)) result[key] = number;
		} else {
			result[key] = value;
		}
	}
	const urls = [source.websocketUrl$, source.secondaryWebsocketUrl$].filter((url) => typeof url === 'string' && url.length > 0);
	if (urls.length > 0) result.websocketUrls = urls;
	return result;
}
