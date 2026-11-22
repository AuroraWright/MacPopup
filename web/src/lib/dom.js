/**
 * Removes all of `element`'s children, one by one. WebKit doesn't free the children removed all at once
 * (`textContent = ''`, `replaceChildren()`, `innerHTML`): it queues them to delete when the page's window is active
 * and the page has time between frames, and the overlay's windows never are active (the game keeps focus). Up to
 * 100,000 nodes stay in memory that way: old OCR readings, popups and lines. Children removed one by one are freed
 * as usual.
 * @param {Element} element
 */
export function clearChildren(element) {
	while (element.lastChild) element.lastChild.remove();
}
