import SwiftUI

/// The trip report card's "Send to dose.wiki" action: builds the session's
/// ``DoseWikiReportDraft``, confirms, then opens dose.wiki's report form in
/// the browser with the session filled in.
struct DoseWikiSendButton: View {
    let session: Session

    @Environment(\.openURL) private var openURL
    @State private var draft: DoseWikiReportDraft?
    @State private var confirming = false

    var body: some View {
        Button {
            draft = DoseWikiReportDraft.build(session: session)
            confirming = true
        } label: {
            Label("Send to dose.wiki", systemImage: "arrow.up.forward.app")
                .sectionLabel()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .tint(Theme.secondaryLabel)
        .alert("Send to dose.wiki?", isPresented: $confirming, presenting: draft) { draft in
            Button("Open") { openURL(draft.url) }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text(verbatim: Self.message(truncated: draft.wasTruncated))
        }
    }

    private static func message(truncated: Bool) -> String {
        let base = String(localized: "This opens dose.wiki's trip report form with this session filled in. Nothing is sent until you submit it there.")
        guard truncated else { return base }
        let note = String(localized: "Some long notes were shortened or left out to fit.")
        return "\(base)\n\n\(note)"
    }
}
