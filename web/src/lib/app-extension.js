// Stands in for OwOtan's messages to the app that holds its Safari extension (ext/js/extension/app-extension.js),
// which its AudioDownloader sends for the local-android-db audio source, served by its iPhone app.

export function isSafariExtension() {
	return false;
}

export async function sendAppExtensionMessage(_message, errorMessage) {
	throw new Error(errorMessage);
}
