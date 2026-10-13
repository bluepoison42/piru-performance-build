// Text helpers for localized content. `String(localized:)` itself comes from SkipAndroidBridge,
// whose default bundle is Skip's main bundle: the Piru module's assets, where the catalog is.

import Foundation

/// Markdown source as the text it renders: emphasis markers and link syntax removed.
nonisolated func androidPlainMarkdown(_ markdown: String) -> String {
    var text = markdown
    text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
    for marker in ["**", "__", "*", "_", "`"] {
        text = text.replacingOccurrences(of: marker, with: "")
    }
    return text
}
