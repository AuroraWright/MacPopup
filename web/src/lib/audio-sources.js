// The audio sources copied from Yomitan (Settings → Import), for the menu on the play buttons, as in
// Yomitan's DisplayAudio: each source lists the audio it has for a word, and any of them can be played
// and used for Anki cards. Plain clicks on the play buttons still go through the Yomitan API.

import { AudioDownloader, getRequiredAudioSources } from '../../../vendor/yomitan/ext/js/media/audio-downloader.js';
import customAudioListSchema from '../../../vendor/yomitan/ext/data/schemas/custom-audio-list-schema.json';
import { getLanguageSummary } from './languages.js';
import { RequestBuilder } from './request-builder.js';
import { getSettings } from './settings.js';

const typeNames = new Map([
	['jpod101', 'JapanesePod101'],
	['language-pod-101', 'LanguagePod101'],
	['jisho', 'Jisho.org'],
	['lingua-libre', 'Lingua Libre'],
	['wiktionary', 'Wiktionary'],
	['text-to-speech', 'Text-to-speech'],
	['text-to-speech-reading', 'Text-to-speech (Kana reading)'],
	['custom', 'Custom URL'],
	['custom-json', 'Custom URL (JSON)'],
]);


class Downloader extends AudioDownloader {
	// Yomitan reads the schema from the extension.
	async _getCustomAudioListSchema() {
		return customAudioListSchema;
	}
}

const downloader = new Downloader(new RequestBuilder());

/**
 * The sources with Yomitan's menu names; a name used by several sources is numbered. With sources
 * configured and default sources enabled, Yomitan's defaults that aren't among them follow.
 * (Without sources, the Yomitan API plays audio from Yomitan's own, defaults included.)
 * @returns {{index: number, type: string, url: string, voice: string, name: string, nameIndex: number, nameUnique: boolean, downloadable: boolean}[]}
 */
export function getAudioSources(settings) {
	const sources = [];
	const byName = new Map();
	const configured = settings.audioSources ?? [];
	// Yomitan's "Enable default audio sources": its sources for the language that aren't configured.
	const defaults = configured.length > 0 && settings.audioDefaultSources !== false
		? getRequiredAudioSources(getLanguageSummary(settings.language).iso, configured).map(({ type }) => ({ type }))
		: [];
	for (const { type, url = '', voice = '' } of [...configured, ...defaults]) {
		const name = typeNames.get(type) ?? 'Unknown';
		const sameName = byName.get(name) ?? [];
		byName.set(name, sameName);
		if (sameName.length === 1) sameName[0].nameUnique = false;
		const source = {
			index: sources.length,
			type,
			url,
			voice,
			name,
			nameIndex: sameName.length,
			nameUnique: sameName.length === 0,
			downloadable: type !== 'text-to-speech' && type !== 'text-to-speech-reading',
		};
		sameName.push(source);
		sources.push(source);
	}
	return sources;
}

// term + reading → source key → {infoList: Promise<{info, valid, audio}[]>}. valid is null until the
// audio has been downloaded.
const cache = new Map();

function sourceKey(source) {
	return `${source.type}\u0000${source.url}\u0000${source.voice}`;
}

function getCacheEntry(term, reading, source) {
	// Sources like LanguagePod101 find different audio for each language.
	const key = `${getSettings().language}\u0000${term}\u0000${reading}`;
	let entries = cache.get(key);
	if (!entries) {
		entries = new Map();
		cache.set(key, entries);
		if (cache.size > 200) cache.delete(cache.keys().next().value);
	}
	let entry = entries.get(sourceKey(source));
	if (!entry) {
		entry = { infoList: null, items: null };
		entries.set(sourceKey(source), entry);
	}
	return entry;
}

/** The audio a source has for the word, or null while it hasn't been asked yet. */
export function getLoadedInfoList(source, term, reading) {
	return getCacheEntry(term, reading, source).items;
}

/** Asks the source which audio it has for the word (once; failures count as none). */
export function loadInfoList(source, term, reading) {
	const entry = getCacheEntry(term, reading, source);
	entry.infoList ??= downloader
		.getTermAudioInfoList(source, term, reading, getLanguageSummary(getSettings().language))
		.catch(() => [])
		.then((infoList) => {
			entry.items = infoList.map((info) => ({ info, valid: null, audio: null }));
			return entry.items;
		});
	return entry.infoList;
}

/**
 * Downloads the audio at `subIndex` of the source's list, or the first that works if it's null.
 * @param {?number} idleTimeout In milliseconds, or null for no limit.
 * @returns {Promise<?{subIndex: number, audio: {type: 'data', data: string, contentType: string} | {type: 'tts', text: string, voice: string}}>}
 */
export async function getAudio(source, term, reading, subIndex, idleTimeout = 10000) {
	const items = await loadInfoList(source, term, reading);
	const indices = subIndex === null ? items.map((_, i) => i) : [subIndex];
	for (const i of indices) {
		const item = items[i];
		if (!item || item.valid === false) continue;
		if (item.audio === null) {
			try {
				item.audio = await download(item.info, source, idleTimeout);
				item.valid = true;
			} catch (_) {
				item.valid = false;
				continue;
			}
		}
		return { subIndex: i, audio: item.audio };
	}
	return null;
}

async function download(info, source, idleTimeout) {
	switch (info.type) {
		case 'url': {
			const { data, contentType } = await downloader._downloadAudioFromUrl(info.url, source.type, idleTimeout);
			return { type: 'data', data, contentType: contentType || 'audio/mpeg' };
		}
		case 'tts':
			return { type: 'tts', text: info.text, voice: info.voice };
		default:
			throw new Error(`Unsupported audio type ${info.type}`);
	}
}

/**
 * Starts playing downloaded audio; returns something with pause() to stop it.
 * @param {number} volume From 0 to 1.
 */
export function startAudio(audio, volume, onError) {
	if (audio.type === 'tts') {
		const utterance = new SpeechSynthesisUtterance(audio.text);
		utterance.lang = 'ja-JP';
		utterance.volume = volume;
		const voice = speechSynthesis.getVoices().find(({ voiceURI }) => voiceURI === audio.voice);
		if (voice) utterance.voice = voice;
		speechSynthesis.cancel();
		speechSynthesis.speak(utterance);
		return { pause: () => speechSynthesis.cancel() };
	}
	const element = new Audio(`data:${audio.contentType};base64,${audio.data}`);
	element.volume = volume;
	element.play().catch(onError);
	return element;
}
