// The Compose side of the timeline graph's milestone stack (Android/SwiftUI/MilestoneStack+Android.swift):
// the placement of the iOS Layout in Shared/TimelineGraphView.swift, with both views measured by
// Compose. The glyph is centered on its moment; the clock time sits under it, slid sideways just
// enough to stay inside the plot (TimelineGraphRenderer.milestoneLabelCenterX on iOS).
package piru.module

import androidx.compose.runtime.Composable
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import skip.ui.ComposeBuilder
import skip.ui.ComposeContext
import skip.ui.ContentComposer
import skip.ui.View

class AndroidMilestoneComposer(
    private val x: Double,
    private val y: Double,
    private val plotMinX: Double,
    private val plotMaxX: Double,
    private val spacing: Double,
    bridgedContent: Any,
) : ContentComposer {
    private val content = ComposeBuilder.from { bridgedContent as View }

    @Composable
    override fun Compose(context: ComposeContext) {
        val renderables = content.Evaluate(context = context, options = 0).filter { !it.isSwiftUIEmptyView }
        val contentContext = context.content()
        Layout(
            modifier = context.modifier,
            content = {
                for (renderable in renderables) {
                    renderable.Render(context = contentContext)
                }
            },
        ) { measurables, constraints ->
            // Each view at its ideal size, as the iOS Layout proposes `.unspecified`.
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            val placeables = measurables.map { it.measure(loose) }
            // The stack fills the graph, so (x, y) are graph coordinates, as on iOS.
            val width = if (constraints.hasBoundedWidth) constraints.maxWidth else constraints.minWidth
            val height = if (constraints.hasBoundedHeight) constraints.maxHeight else constraints.minHeight
            layout(width, height) {
                if (placeables.size != 2) return@layout
                val glyph = placeables[0]
                val label = placeables[1]
                val centerX = x.dp.toPx()
                val gap = spacing.dp.toPx()
                val top = y.dp.toPx() - (glyph.height + gap + label.height) / 2f
                glyph.placeRelative((centerX - glyph.width / 2f).roundToInt(), top.roundToInt())
                val lowest = plotMinX.dp.toPx() + label.width / 2f
                val highest = plotMaxX.dp.toPx() - label.width / 2f
                val labelCenter = if (lowest <= highest) centerX.coerceIn(lowest, highest) else (lowest + highest) / 2f
                label.placeRelative((labelCenter - label.width / 2f).roundToInt(), (top + glyph.height + gap).roundToInt())
            }
        }
    }
}
