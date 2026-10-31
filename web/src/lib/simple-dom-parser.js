// Stands in for Yomitan's parse5-based SimpleDOMParser: WebKit has DOMParser, which
// NativeSimpleDOMParser uses instead, so this is never needed.

export class SimpleDOMParser {
	static isSupported() {
		return false;
	}
}
