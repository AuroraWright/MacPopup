/*
 * Copyright (C) 2023-2026  Yomitan Authors
 * Copyright (C) 2021-2022  Yomichan Authors
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

export class ElementOverflowController {
    /**
     * @param {import('./display.js').Display} display
     * @param {Element} scrollElement
     */
    constructor(display, scrollElement) {
        /** @type {import('./display.js').Display} */
        this._display = display;
        /** @type {Element} */
        this._scrollElement = scrollElement;
        /** @type {Element[]} */
        this._elements = [];
        /** @type {Map<Element, Element[]>} */
        this._observedEntries = new Map();
        /** @type {?IntersectionObserver} */
        this._intersectionObserver = null;
        /** @type {?(number|import('core').Timeout)} */
        this._checkTimer = null;
        /** @type {EventListenerCollection} */
        this._eventListeners = new EventListenerCollection();
        /** @type {EventListenerCollection} */
        this._windowEventListeners = new EventListenerCollection();
        /** @type {Map<string, {collapsed: boolean, force: boolean}>} */
        this._dictionaries = new Map();
        /** @type {() => void} */
        this._updateBind = this._update.bind(this);
        /** @type {() => void} */
        this._onWindowResizeBind = this._onWindowResize.bind(this);
        /** @type {(event: MouseEvent) => void} */
        this._onToggleButtonClickBind = this._onToggleButtonClick.bind(this);
    }

    /**
     * @param {import('settings').ProfileOptions} options
     */
    setOptions(options) {
        this._dictionaries.clear();
        for (const {name, definitionsCollapsible} of options.dictionaries) {
            let collapsible = false;
            let collapsed = false;
            let force = false;
            switch (definitionsCollapsible) {
                case 'expanded':
                    collapsible = true;
                    break;
                case 'collapsed':
                    collapsible = true;
                    collapsed = true;
                    break;
                case 'force-expanded':
                    collapsible = true;
                    force = true;
                    break;
                case 'force-collapsed':
                    collapsible = true;
                    collapsed = true;
                    force = true;
                    break;
            }
            if (!collapsible) { continue; }
            this._dictionaries.set(name, {collapsed, force});
        }
    }

    /**
     * @param {Element} entry
     */
    addElements(entry) {
        if (this._dictionaries.size === 0) { return; }


        /** @type {Element[]} */
        const elements = [
            ...entry.querySelectorAll('.definition-item-inner'),
            ...entry.querySelectorAll('.kanji-glyph-data'),
        ];
        /** @type {Element[]} */
        const elementsToUpdate = [];
        for (const element of elements) {
            const {parentNode} = element;
            if (parentNode === null) { continue; }
            const {dictionary} = /** @type {HTMLElement} */ (parentNode).dataset;
            if (typeof dictionary === 'undefined') { continue; }
            const dictionaryInfo = this._dictionaries.get(dictionary);
            if (typeof dictionaryInfo === 'undefined') { continue; }

            if (dictionaryInfo.force) {
                element.classList.add('collapsible', 'collapsible-forced');
            } else {
                elementsToUpdate.push(element);
            }

            if (dictionaryInfo.collapsed) {
                element.classList.add('collapsed');
            }

            const button = element.querySelector('.expansion-button');
            if (button !== null) {
                this._eventListeners.addEventListener(button, 'click', this._onToggleButtonClickBind, false);
            }
        }
        if (elementsToUpdate.length > 0) {
            // Measuring the elements makes the browser lay out the page, including entries far from the visible part of
            // it, which it otherwise only lays out once they come near it (they have `content-visibility: auto`). So each
            // entry is measured once it comes near it, and until then, the elements that start collapsed are kept as
            // short as the test makes them.
            for (const element of elementsToUpdate) {
                if (element.classList.contains('collapsed')) {
                    element.classList.add('collapse-test');
                }
            }
            if (this._intersectionObserver === null) {
                this._intersectionObserver = new IntersectionObserver(this._onIntersection.bind(this), {root: this._scrollElement, rootMargin: '100% 0px'});
            }
            this._intersectionObserver.observe(entry);
            this._observedEntries.set(entry, elementsToUpdate);
        }

        if (elementsToUpdate.length > 0 && this._windowEventListeners.size === 0) {
            this._windowEventListeners.addEventListener(window, 'resize', this._onWindowResizeBind, false);
        }
    }

    /**
     * Checks an entry's elements now if it is in the visible part of the page. The observer only reports it after the
     * page has been drawn, which would show it without its expansion buttons until then. The display only does this for
     * the first entry: measuring the others before the page is drawn would make the browser lay out every entry added
     * with them.
     * @param {Element} entry
     */
    checkEntryIfVisible(entry) {
        const elements = this._observedEntries.get(entry);
        if (typeof elements === 'undefined') { return; }
        const {top, bottom} = this._scrollElement.getBoundingClientRect();
        const rect = entry.getBoundingClientRect();
        if (rect.bottom <= top || rect.top >= bottom) { return; }
        this._observedEntries.delete(entry);
        /** @type {IntersectionObserver} */ (this._intersectionObserver).unobserve(entry);
        this._elements.push(...elements);
        this._updateElements(elements);
    }

    /** */
    clearElements() {
        this._elements.length = 0;
        this._observedEntries.clear();
        if (this._intersectionObserver !== null) {
            this._intersectionObserver.disconnect();
        }
        this._eventListeners.removeAllEventListeners();
        this._windowEventListeners.removeAllEventListeners();
    }

    // Private

    /** */
    _onWindowResize() {
        if (this._checkTimer !== null) {
            this._cancelIdleCallback(this._checkTimer);
        }
        this._checkTimer = this._requestIdleCallback(this._updateBind, 100);
    }

    /**
     * @param {MouseEvent} e
     */
    _onToggleButtonClick(e) {
        const element = /** @type {Element} */ (e.currentTarget);
        /** @type {(Element | null)[]} */
        const collapsedElements = [
            element.closest('.definition-item-inner'),
            element.closest('.kanji-glyph-data'),
        ];
        for (const collapsedElement of collapsedElements) {
            if (collapsedElement === null) { continue; }
            const collapsed = collapsedElement.classList.toggle('collapsed');
            if (collapsed) {
                this._display.scrollUpToElementTop(element);
            }
        }
    }

    /** */
    _update() {
        this._updateElements(this._elements);
    }

    /**
     * @param {IntersectionObserverEntry[]} records
     */
    _onIntersection(records) {
        /** @type {Element[]} */
        const elements = [];
        for (const {target, isIntersecting} of records) {
            if (!isIntersecting) { continue; }
            const entryElements = this._observedEntries.get(target);
            if (typeof entryElements === 'undefined') { continue; }
            this._observedEntries.delete(target);
            /** @type {IntersectionObserver} */ (this._intersectionObserver).unobserve(target);
            elements.push(...entryElements);
        }
        this._elements.push(...elements);
        this._updateElements(elements);
    }

    /**
     * Checks which elements are long enough to be collapsible. All of them are measured together:
     * reading an element's size right after changing its classes makes the browser lay out the whole
     * page again, so checking them one at a time costs a layout for each.
     * Their entries are laid out while they are measured: Safari before 26 reads every size in an entry that
     * `content-visibility: auto` skips as 0, and the observer can report elements in such entries, which then were
     * not made collapsible. Later versions lay out a skipped entry to measure it anyway.
     * @param {Element[]} elements
     */
    _updateElements(elements) {
        /** @type {Set<HTMLElement>} */
        const entries = new Set();
        for (const element of elements) {
            const entry = element.closest('.entry');
            if (entry instanceof HTMLElement) { entries.add(entry); }
        }
        for (const entry of entries) {
            entry.style.setProperty('content-visibility', 'visible');
        }
        for (const element of elements) {
            element.classList.add('collapse-test');
        }
        const collapsible = elements.map((element) => element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth);
        for (let i = 0, ii = elements.length; i < ii; ++i) {
            const {classList} = elements[i];
            classList.toggle('collapsible', collapsible[i]);
            classList.remove('collapse-test');
        }
        for (const entry of entries) {
            entry.style.removeProperty('content-visibility');
        }
    }

    /**
     * @param {() => void} callback
     * @param {number} timeout
     * @returns {number|import('core').Timeout}
     */
    _requestIdleCallback(callback, timeout) {
        return (
            typeof requestIdleCallback === 'function' ?
            requestIdleCallback(callback, {timeout}) :
            setTimeout(callback, timeout)
        );
    }

    /**
     * @param {number|import('core').Timeout} handle
     */
    _cancelIdleCallback(handle) {
        if (typeof cancelIdleCallback === 'function') {
            cancelIdleCallback(/** @type {number} */ (handle));
        } else {
            clearTimeout(handle);
        }
    }
}
