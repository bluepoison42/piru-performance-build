// The timeline graph's milestone stack for Android (`MilestoneStackLayout` in
// Shared/TimelineGraphView.swift, which patch 0020 points here). The upstream type is a custom
// `Layout`, a protocol SkipFuseUI does not provide, so the glyph and its clock time go to a
// Compose layout (Skip/AndroidMilestoneComposer.kt) that places them as the iOS one does: the
// glyph centered on its moment, the time under it, slid sideways by its measured width when
// centering it would run past either edge of the plot.

import SkipBridge
import SwiftUI

struct AndroidMilestoneStackLayout<Content: View>: View {
    let x: CGFloat
    let y: CGFloat
    let geom: TimelineGraphRenderer.GraphGeometry
    @ViewBuilder let content: Content

    var body: some View {
        let children = content.Java_viewOrEmpty
        let x = Double(x)
        let y = Double(y)
        let plotMinX = Double(geom.inset)
        let plotMaxX = Double(geom.inset + geom.width)
        let spacing = Double(TimelineGraphRenderer.MilestoneMetrics.spacing)
        return ComposeView {
            try! AnyDynamicObject(
                className: "piru.module.AndroidMilestoneComposer", x, y, plotMinX, plotMaxX, spacing, children,
            )
        }
    }
}
