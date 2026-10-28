import Foundation

/// Where on the body an injected dose went: an area and a side.
///
/// Persisted on ``DoseEntry/injectionSiteRaw`` as `"<area>.<side>"`
/// (`"thigh.left"`) so the field-add stays a lightweight migration and a site
/// this build doesn't know reads as `nil` rather than failing to decode.
nonisolated struct InjectionSite: Hashable, Sendable {
    nonisolated enum Area: String, CaseIterable, Sendable {
        case abdomen
        case thigh
        case glute
        case ventrogluteal
        case arm

        /// The areas offered for a route: the hip site is an intramuscular one,
        /// the abdomen a subcutaneous one.
        static func offered(for route: RouteOfAdministration) -> [Area] {
            switch route {
            case .intramuscular: [.thigh, .glute, .ventrogluteal, .arm]
            case .subcutaneous: [.abdomen, .thigh, .glute, .arm]
            default: []
            }
        }
    }

    nonisolated enum Side: String, CaseIterable, Sendable {
        case left
        case right

        var opposite: Side {
            self == .left ? .right : .left
        }
    }

    var area: Area
    var side: Side

    init(area: Area, side: Side) {
        self.area = area
        self.side = side
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let area = Area(rawValue: parts[0]), let side = Side(rawValue: parts[1]) else {
            return nil
        }
        self.init(area: area, side: side)
    }

    var rawValue: String {
        "\(area.rawValue).\(side.rawValue)"
    }

    /// "Left thigh", "Right hip (ventrogluteal)". Each pair is its own string
    /// so a language that agrees the side with the area's gender can.
    var label: String {
        switch (area, side) {
        case (.abdomen, .left): String(localized: "Left abdomen")
        case (.abdomen, .right): String(localized: "Right abdomen")
        case (.thigh, .left): String(localized: "Left thigh")
        case (.thigh, .right): String(localized: "Right thigh")
        case (.glute, .left): String(localized: "Left glute")
        case (.glute, .right): String(localized: "Right glute")
        case (.ventrogluteal, .left): String(localized: "Left hip (ventrogluteal)")
        case (.ventrogluteal, .right): String(localized: "Right hip (ventrogluteal)")
        case (.arm, .left): String(localized: "Left arm")
        case (.arm, .right): String(localized: "Right arm")
        }
    }

    /// The same label lowercased for use inside a sentence ("Next: left thigh").
    var inlineLabel: String {
        label.lowercased(with: .current)
    }

    /// Whether a route takes an injection site. Intravenous doses are left
    /// out: the areas and sides here are intramuscular and subcutaneous sites.
    static func applies(to route: RouteOfAdministration) -> Bool {
        !Area.offered(for: route).isEmpty
    }

    /// The site to suggest after `last`: the same area on the other side, so a
    /// left/right alternation is the default rotation. `nil` when nothing was
    /// logged yet, or when the last area isn't offered for `route`.
    static func suggestedNext(after last: InjectionSite?, route: RouteOfAdministration) -> InjectionSite? {
        guard let last, Area.offered(for: route).contains(last.area) else { return nil }
        return InjectionSite(area: last.area, side: last.side.opposite)
    }
}
