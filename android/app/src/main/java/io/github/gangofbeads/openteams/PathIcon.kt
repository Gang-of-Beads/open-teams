package io.github.gangofbeads.openteams

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import androidx.core.graphics.PathParser
import androidx.core.graphics.withTranslation

/** An SVG icon from Teams' page (path data and viewBox), drawn natively in one color. */
class PathIcon(pathData: String, private val viewBoxWidth: Float, private val viewBoxHeight: Float, private val sizePx: Int) : Drawable() {
    private val path: Path = PathParser.createPathFromPathData(pathData)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

    fun tint(color: Int) = apply { paint.color = color }

    override fun draw(canvas: Canvas) {
        canvas.withTranslation(bounds.left.toFloat(), bounds.top.toFloat()) {
            scale(bounds.width() / viewBoxWidth, bounds.height() / viewBoxHeight)
            drawPath(path, paint)
        }
    }

    override fun getIntrinsicWidth() = sizePx

    override fun getIntrinsicHeight() = (sizePx * viewBoxHeight / viewBoxWidth).toInt()

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Drawable")
    override fun getOpacity() = PixelFormat.TRANSLUCENT

    companion object {
        /** "0 0 20 20" → icon, or null when Teams sent something unusable. */
        fun from(pathData: String, viewBox: String, dpPerUnit: Float, density: Float): PathIcon? {
            val box = viewBox.trim().split(Regex("[\\s,]+")).mapNotNull { it.toFloatOrNull() }
            if (box.size != 4 || box[2] <= 0 || box[3] <= 0) return null
            return runCatching { PathIcon(pathData, box[2], box[3], (box[2] * dpPerUnit * density).toInt()) }.getOrNull()
        }
    }
}
