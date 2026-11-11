/*
 * Copyright (C) 2023-2026  Yomitan Authors
 * Copyright (C) 2020-2022  Yomichan Authors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import {EventListenerCollection} from '../core/event-listener-collection.js';
import {log} from '../core/log.js';
import {base64ToArrayBuffer} from '../data/array-buffer-util.js';

/**
 * The content manager which is used when generating HTML display content.
 */
export class DisplayContentManager {
    /**
     * Creates a new instance of the class.
     * @param {import('./display.js').Display} display The display instance that owns this object.
     */
    constructor(display) {
        /** @type {import('./display.js').Display} */
        this._display = display;
        /** @type {import('core').TokenObject} */
        this._token = {};
        /** @type {EventListenerCollection} */
        this._eventListeners = new EventListenerCollection();
        /** @type {import('display-content-manager').LoadMediaRequest[]} */
        this._loadMediaRequests = [];
    }

    /** @type {import('display-content-manager').LoadMediaRequest[]} */
    get loadMediaRequests() {
        return this._loadMediaRequests;
    }

    /**
     * Queues loading media file from a given dictionary.
     * @param {string} path
     * @param {string} dictionary
     * @param {HTMLCanvasElement} canvas
     */
    loadMedia(path, dictionary, canvas) {
        this._loadMediaRequests.push({path, dictionary, canvas});
    }

    /**
     * Unloads all media that has been loaded.
     */
    unloadAll() {
        this._token = {};

        this._eventListeners.removeAllEventListeners();

        this._loadMediaRequests = [];
    }

    /**
     * Sets up attributes and events for a link element.
     * @param {HTMLAnchorElement} element The link element.
     * @param {string} href The URL.
     * @param {boolean} internal Whether or not the URL is an internal or external link.
     */
    prepareLink(element, href, internal) {
        element.href = href;
        if (!internal) {
            element.target = '_blank';
            element.rel = 'noreferrer noopener';
        }
        this._eventListeners.addEventListener(element, 'click', this._onLinkClick.bind(this));
    }

    /**
     * Execute media requests
     */
    async executeMediaRequests() {
        const {api} = this._display.application;
        if (api.canDrawMedia) {
            const requests = this._loadMediaRequests.map(({path, dictionary, canvas}) => ({path, dictionary, canvas: canvas.transferControlToOffscreen()}));
            api.drawMedia(requests, requests.map(({canvas}) => canvas));
        } else {
            void this._drawMediaFromBackend(this._loadMediaRequests);
        }
        this._loadMediaRequests = [];
    }

    /**
     * @param {string} path
     * @param {string} dictionary
     * @param {Window} window
     */
    async openMediaInTab(path, dictionary, window) {
        // Safari only opens a tab while the click is being handled, so there it is opened before the file is read, and
        // goes to the file once it has been read.
        const safariWindow = this._display.browser === 'safari' ? window.open('', '_blank') : null;
        const data = await this._display.application.api.getMedia([{path, dictionary}]);
        const buffer = base64ToArrayBuffer(data[0].content);
        const blob = new Blob([buffer], {type: data[0].mediaType});
        const blobUrl = URL.createObjectURL(blob);
        if (safariWindow !== null) {
            safariWindow.location.href = blobUrl;
            safariWindow.focus();
            return;
        }
        window.open(blobUrl, '_blank')?.focus();
    }

    /**
     * Draws images by reading them from the backend, for pages without the media drawing worker. This is slower.
     * Monochrome images are colored here: Safari leaves out the drop-shadow of the CSS filter that colors them in other
     * browsers (structured-content.css).
     * @param {import('display-content-manager').LoadMediaRequest[]} requests
     */
    async _drawMediaFromBackend(requests) {
        const token = this._token;
        // Read each image once, and draw it into every canvas that shows it.
        /** @type {Map<string, {path: string, dictionary: string, canvases: HTMLCanvasElement[]}>} */
        const groups = new Map();
        for (const {path, dictionary, canvas} of requests) {
            const key = `${path}:::${dictionary}`;
            const group = groups.get(key);
            if (typeof group === 'undefined') {
                groups.set(key, {path, dictionary, canvases: [canvas]});
            } else {
                group.canvases.push(canvas);
            }
        }
        if (groups.size === 0) { return; }

        const media = await this._display.application.api.getMedia([...groups.values()].map(({path, dictionary}) => ({path, dictionary})));
        for (const {content, mediaType, path, dictionary} of media) {
            if (token !== this._token) { return; }
            const group = groups.get(`${path}:::${dictionary}`);
            if (typeof group === 'undefined') { continue; }
            const url = URL.createObjectURL(new Blob([base64ToArrayBuffer(content)], {type: mediaType}));
            try {
                const image = new Image();
                image.src = url;
                await image.decode();
                for (const canvas of group.canvases) {
                    const context = canvas.getContext('2d');
                    if (context === null) { continue; }
                    context.imageSmoothingQuality = 'high';
                    context.drawImage(image, 0, 0, canvas.width, canvas.height);
                    if (canvas.closest('.gloss-image-link[data-appearance=monochrome]') !== null) {
                        context.globalCompositeOperation = 'source-in';
                        context.fillStyle = getComputedStyle(canvas).getPropertyValue('--text-color');
                        context.fillRect(0, 0, canvas.width, canvas.height);
                        context.globalCompositeOperation = 'source-over';
                    }
                }
            } catch (e) {
                log.error(e);
            } finally {
                URL.revokeObjectURL(url);
            }
        }
    }

    /**
     * @param {MouseEvent} e
     */
    _onLinkClick(e) {
        const {href} = /** @type {HTMLAnchorElement} */ (e.currentTarget);
        if (typeof href !== 'string') { return; }

        const baseUrl = new URL(location.href);
        const url = new URL(href, baseUrl);
        const internal = (url.protocol === baseUrl.protocol && url.host === baseUrl.host);
        if (!internal) { return; }

        e.preventDefault();

        /** @type {import('display').HistoryParams} */
        const params = {};
        for (const [key, value] of url.searchParams.entries()) {
            params[key] = value;
        }
        this._display.setContent({
            historyMode: 'new',
            focus: false,
            params,
            state: null,
            content: null,
        });
    }
}
