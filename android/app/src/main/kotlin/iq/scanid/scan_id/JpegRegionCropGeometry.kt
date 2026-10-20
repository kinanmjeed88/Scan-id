package iq.scanid.scan_id

import kotlin.math.ceil
import kotlin.math.floor

/** Pixel edges shared by the production Android region decoder and its tests. */
internal data class JpegRegionCropBounds(
    val orientedWidth: Int,
    val orientedHeight: Int,
    val orientedLeft: Int,
    val orientedTop: Int,
    val orientedRight: Int,
    val orientedBottom: Int,
    val rawLeft: Int,
    val rawTop: Int,
    val rawRight: Int,
    val rawBottom: Int,
) {
    val outputWidth: Int get() = orientedRight - orientedLeft
    val outputHeight: Int get() = orientedBottom - orientedTop
    val rawWidth: Int get() = rawRight - rawLeft
    val rawHeight: Int get() = rawBottom - rawTop
}

/**
 * Maps an EXIF-oriented normalized rectangle to the exact raw JPEG pixel edges.
 * The production decoder passes these raw bounds directly to `decodeRegion`;
 * the instrumentation suite checks them against independent fixtures.
 */
internal fun calculateJpegRegionCropBounds(
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: Int,
    left: Double,
    top: Double,
    right: Double,
    bottom: Double,
): JpegRegionCropBounds {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(orientation in 1..8)
    require(
        left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite() &&
            left >= 0.0 && top >= 0.0 && right <= 1.0 && bottom <= 1.0 &&
            left < right && top < bottom,
    )

    val (orientedWidth, orientedHeight) = orientedSize(
        sourceWidth,
        sourceHeight,
        orientation,
    )
    val orientedLeft = floor(left * orientedWidth).toInt()
        .coerceIn(0, orientedWidth)
    val orientedTop = floor(top * orientedHeight).toInt()
        .coerceIn(0, orientedHeight)
    val orientedRight = ceil(right * orientedWidth).toInt()
        .coerceIn(0, orientedWidth)
    val orientedBottom = ceil(bottom * orientedHeight).toInt()
        .coerceIn(0, orientedHeight)
    require(orientedLeft < orientedRight && orientedTop < orientedBottom)

    val rawCorners = listOf(
        rawPoint(
            orientedLeft.toDouble(),
            orientedTop.toDouble(),
            sourceWidth,
            sourceHeight,
            orientation,
        ),
        rawPoint(
            orientedRight.toDouble(),
            orientedTop.toDouble(),
            sourceWidth,
            sourceHeight,
            orientation,
        ),
        rawPoint(
            orientedRight.toDouble(),
            orientedBottom.toDouble(),
            sourceWidth,
            sourceHeight,
            orientation,
        ),
        rawPoint(
            orientedLeft.toDouble(),
            orientedBottom.toDouble(),
            sourceWidth,
            sourceHeight,
            orientation,
        ),
    )
    val rawLeft = floor(rawCorners.minOf { it.first })
        .toInt().coerceIn(0, sourceWidth)
    val rawTop = floor(rawCorners.minOf { it.second })
        .toInt().coerceIn(0, sourceHeight)
    val rawRight = ceil(rawCorners.maxOf { it.first })
        .toInt().coerceIn(0, sourceWidth)
    val rawBottom = ceil(rawCorners.maxOf { it.second })
        .toInt().coerceIn(0, sourceHeight)
    require(rawLeft < rawRight && rawTop < rawBottom)

    return JpegRegionCropBounds(
        orientedWidth = orientedWidth,
        orientedHeight = orientedHeight,
        orientedLeft = orientedLeft,
        orientedTop = orientedTop,
        orientedRight = orientedRight,
        orientedBottom = orientedBottom,
        rawLeft = rawLeft,
        rawTop = rawTop,
        rawRight = rawRight,
        rawBottom = rawBottom,
    )
}

private fun rawPoint(
    x: Double,
    y: Double,
    width: Int,
    height: Int,
    orientation: Int,
): Pair<Double, Double> = when (orientation) {
    1 -> x to y
    2 -> width - x to y
    3 -> width - x to height - y
    4 -> x to height - y
    5 -> y to x
    6 -> y to height - x
    7 -> width - y to height - x
    8 -> width - y to x
    else -> error("Invalid EXIF orientation")
}

private fun orientedSize(width: Int, height: Int, orientation: Int): Pair<Int, Int> =
    if (orientation in 5..8) height to width else width to height
