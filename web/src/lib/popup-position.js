// Port of the popup placement logic in Yomitan's ext/js/app/popup.js.

function getConstrainedPosition(positionBefore, positionAfter, size, minLimit, maxLimit, after) {
	size = Math.min(size, maxLimit - minLimit);
	let position;
	if (after) {
		position = Math.max(minLimit, positionAfter);
		position = position - Math.max(0, position + size - maxLimit);
	} else {
		position = Math.min(maxLimit, positionBefore) - size;
		position = position + Math.max(0, minLimit - position);
	}
	return [position, size, after];
}

function getConstrainedPositionBinary(positionBefore, positionAfter, size, minLimit, maxLimit, after) {
	const overflowBefore = minLimit - (positionBefore - size);
	const overflowAfter = positionAfter + size - maxLimit;
	if (overflowAfter > 0 || overflowBefore > 0) {
		after = overflowAfter < overflowBefore;
	}
	let position;
	if (after) {
		size -= Math.max(0, overflowAfter);
		position = Math.max(minLimit, positionAfter);
	} else {
		size -= Math.max(0, overflowBefore);
		position = Math.min(maxLimit, positionBefore) - size;
	}
	return [position, size, after];
}

function getPositionForHorizontalText(sourceRect, frameWidth, frameHeight, viewport, horizontalOffset, verticalOffset, preferBelow) {
	const [left, width, after] = getConstrainedPosition(
		sourceRect.right - horizontalOffset,
		sourceRect.left + horizontalOffset,
		frameWidth,
		viewport.left,
		viewport.right,
		true,
	);
	const [top, height, below] = getConstrainedPositionBinary(
		sourceRect.top - verticalOffset,
		sourceRect.bottom + verticalOffset,
		frameHeight,
		viewport.top,
		viewport.bottom,
		preferBelow,
	);
	return { left, top, width, height, after, below };
}

function getPositionForVerticalText(sourceRect, frameWidth, frameHeight, viewport, horizontalOffset, verticalOffset, preferRight) {
	const [left, width, after] = getConstrainedPositionBinary(
		sourceRect.left - horizontalOffset,
		sourceRect.right + horizontalOffset,
		frameWidth,
		viewport.left,
		viewport.right,
		preferRight,
	);
	const [top, height, below] = getConstrainedPosition(
		sourceRect.bottom - verticalOffset,
		sourceRect.top + verticalOffset,
		frameHeight,
		viewport.top,
		viewport.bottom,
		true,
	);
	return { left, top, width, height, after, below };
}

export function getBoundingSourceRect(sourceRects) {
	if (sourceRects.length === 0) return { left: 0, top: 0, right: 0, bottom: 0 };
	let { left, top, right, bottom } = sourceRects[0];
	for (const rect of sourceRects.slice(1)) {
		left = Math.min(left, rect.left);
		top = Math.min(top, rect.top);
		right = Math.max(right, rect.right);
		bottom = Math.max(bottom, rect.bottom);
	}
	return { left, top, right, bottom };
}

function isOverlapping(sizeRect, sourceRects, ignoreIndex) {
	const { left, top } = sizeRect;
	const right = left + sizeRect.width;
	const bottom = top + sizeRect.height;
	return sourceRects.some(
		(sourceRect, i) =>
			i !== ignoreIndex && left < sourceRect.right && right > sourceRect.left && top < sourceRect.bottom && bottom > sourceRect.top,
	);
}

/**
 * @param {{left: number, top: number, right: number, bottom: number}[]} sourceRects
 * @param {boolean} verticalText Whether the source text uses a vertical writing mode.
 * @param {{left: number, top: number, right: number, bottom: number}} viewport
 * @param {{frameWidth: number, frameHeight: number, scale: number}} size
 * @param {object} settings
 */
export function getPopupPosition(sourceRects, verticalText, viewport, { frameWidth, frameHeight, scale }, settings) {
	const horizontal = !verticalText || settings.popupVerticalTextPosition === 'default';
	let preferAfter;
	let horizontalOffset;
	let verticalOffset;
	if (horizontal) {
		preferAfter = settings.popupHorizontalTextPosition === 'below';
		horizontalOffset = settings.popupHorizontalOffset;
		verticalOffset = settings.popupVerticalOffset;
	} else {
		// Vertical writing mode here is always vertical-rl, where "before" is the right side.
		preferAfter = ['before', 'right'].includes(settings.popupVerticalTextPosition);
		horizontalOffset = settings.popupHorizontalOffset2;
		verticalOffset = settings.popupVerticalOffset2;
	}
	horizontalOffset *= scale;
	verticalOffset *= scale;

	let best = null;
	const count = sourceRects.length;
	for (let i = 0, ii = count > 1 ? count : 0; i <= ii; ++i) {
		const sourceRect = i < count ? sourceRects[i] : getBoundingSourceRect(sourceRects);
		const result = horizontal
			? getPositionForHorizontalText(sourceRect, frameWidth, frameHeight, viewport, horizontalOffset, verticalOffset, preferAfter)
			: getPositionForVerticalText(sourceRect, frameWidth, frameHeight, viewport, horizontalOffset, verticalOffset, preferAfter);
		if (i < ii && isOverlapping(result, sourceRects, i)) continue;
		if (best === null || result.height > best.height) {
			best = result;
			if (result.height >= frameHeight) break;
		}
	}

	if (settings.popupDisplayMode === 'full-width') {
		const sourceRect = getBoundingSourceRect(sourceRects);
		best.left = viewport.left;
		best.width = viewport.right - viewport.left;
		const overflowBelow = sourceRect.bottom + best.height > viewport.bottom;
		best.top = overflowBelow ? viewport.top : viewport.bottom - best.height;
		best.below = !overflowBelow;
	}
	return best;
}
