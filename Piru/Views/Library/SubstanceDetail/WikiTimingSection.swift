import SwiftUI

/// Reference windows and study statistics stay distinct from the session model.
struct WikiTimingSection: View {
    let records: [WikiTimingRecord]
    @State private var isExpanded = false

    var body: some View {
        if !records.isEmpty {
            CollapsibleSection("substance.wiki timelines", count: records.count, isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            HStack {
                                routeTitle(record).font(.headline)
                                Spacer()
                                Text("Reference \(record.entryIndex + 1)")
                                    .font(.caption)
                            }
                            if let formulation = record.formulation {
                                Text(verbatim: formulation).captionSecondary()
                            }
                            if record.hasSourceException {
                                Text("This source entry has a recorded timing or route concern.").captionSecondary()
                            }
                            if let chart = record.chart {
                                chartContent(chart)
                            } else if let curve = record.curve {
                                legacy(curve, partial: record.kind == "partial_duration_curve")
                            }
                            if let study = record.study {
                                studyContent(study, timingText: record.timingText)
                            }
                            if let url = record.sourceURL {
                                Link("Read source context", destination: url).font(.caption)
                            }
                        }
                        if record.id != records.last?.id { Divider() }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    /// A route the app knows reads in the app language. A study's route is a
    /// machine value, so an unrecognized one reads as unknown; a timing entry's
    /// route is the source's own wording and stays as published.
    private func routeTitle(_ record: WikiTimingRecord) -> Text {
        guard let route = record.route else { return Text("Route unknown") }
        let parsed = RouteOfAdministration.from(string: route)
        if parsed != .other { return Text(parsed.localizedName) }
        return record.kind == "duration_study" ? Text("Route unknown") : Text(verbatim: route)
    }

    private func chartContent(_ chart: WikiDurationChart) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let evidence = WikiTimingLabels.evidence(kind: chart.kind, evidence: chart.evidence) {
                Text(evidence).font(.subheadline.bold())
            }
            if let label = chart.label { Text(verbatim: label).captionSecondary() }
            if chart.kind == "plasma_concentration" {
                plasmaModel(chart)
            } else if let curve = chart.curve {
                Text("Reference timing chart for one administration. Inferred or unknown phases are not used to predict your session.")
                    .captionSecondary()
                WikiTimingWindowRow("Onset", window: curve.onset, units: curve.units, maximum: curve.plotMaximum)
                WikiTimingWindowRow("Peak", window: curve.peak, units: curve.units, maximum: curve.plotMaximum)
                WikiTimingWindowRow("Offset", window: curve.offset, units: curve.units, maximum: curve.plotMaximum)
                if curve.afterEffects != nil {
                    WikiTimingWindowRow("After-effects", window: curve.afterEffects, units: curve.units, maximum: curve.plotMaximum)
                }
                if let total = curve.total {
                    HStack {
                        Text("Reported total")
                        Spacer()
                        Text(verbatim: "\(wikiTimingNumber(total.min)) – \(wikiTimingNumber(total.max)) \(wikiTimingUnits(curve.units))")
                    }
                    .font(.caption)
                }
            }
            if let hypothesis = chart.hypothesis {
                if let confidence = WikiTimingLabels.confidence(hypothesis.confidence) {
                    HStack {
                        Text("Confidence")
                        Spacer()
                        Text(confidence)
                    }
                    .font(.caption)
                }
                if let attribution = hypothesis.attribution { Text(verbatim: attribution).captionSecondary() }
            }
            chartNotes(chart)
        }
    }

    private func plasmaModel(_ chart: WikiDurationChart) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Modeled drug level in plasma, which is not the same as felt effects. It is not used to predict your session.")
                .captionSecondary()
            if let analyte = chart.analyte?.name {
                HStack {
                    Text("Analyte")
                    Spacer()
                    Text(verbatim: analyte)
                }
                .font(.caption)
            }
            if let tmax = chart.parameters?.tmaxHours {
                HStack {
                    Text("Model time to peak level")
                    Spacer()
                    Text(verbatim: "\(wikiTimingNumber(tmax)) \(wikiTimingUnits("hours"))")
                }
                .font(.caption)
            }
            if let halfLife = chart.parameters?.halfLifeHours {
                HStack {
                    Text("Model half-life")
                    Spacer()
                    Text(verbatim: "\(wikiTimingNumber(halfLife)) \(wikiTimingUnits("hours"))")
                }
                .font(.caption)
            }
        }
    }

    /// Limitations, warnings and assumptions are the source's own prose.
    private func chartNotes(_ chart: WikiDurationChart) -> some View {
        let notes = (chart.limitations ?? []) + (chart.warnings ?? []) + (chart.assumptions ?? [])
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            if !notes.isEmpty {
                Text("Limitations").font(.caption.bold())
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(verbatim: note).captionSecondary()
                }
            }
            ForEach(chart.sources ?? []) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) { Text(verbatim: source.title) }.font(.caption)
                }
            }
        }
    }

    private func legacy(_ curve: WikiTimingCurve, partial: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if partial { Text("Partial timing data").font(.subheadline.bold()) }
            Text("Published timing illustration. Phase clock origins are unverified. Unknown timings are not estimated or used to predict your session.")
                .captionSecondary()
            WikiTimingWindowRow("Onset", window: curve.onset, units: curve.units, maximum: curve.plotMaximum)
            WikiTimingWindowRow("Peak", window: curve.peak, units: curve.units, maximum: curve.plotMaximum)
            WikiTimingWindowRow("Offset", window: curve.offset, units: curve.units, maximum: curve.plotMaximum)
            WikiTimingWindowRow("After-effects", window: curve.afterEffects, units: curve.units, maximum: curve.plotMaximum)
            if let total = curve.total {
                HStack {
                    Text("Reported total")
                    Spacer()
                    Text(verbatim: "\(wikiTimingNumber(total.min)) – \(wikiTimingNumber(total.max)) \(wikiTimingUnits(curve.units))")
                }
                .font(.caption)
                if let note = total.note { Text(verbatim: note).captionSecondary() }
            }
            if let reference = curve.reference {
                Text(verbatim: reference).captionSecondary()
            }
        }
    }

    private func studyContent(_ study: WikiTimingStudy, timingText: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Study timeline").font(.subheadline.bold())
            Text("Study statistics describe this condition, not a prediction of your session. The maximum response is a time point, not a peak plateau.")
                .captionSecondary()
            HStack {
                Text("Study dose (µg base)")
                Spacer()
                Text(verbatim: wikiTimingNumber(study.nominalStudyDoseMicrogramsBase))
            }
            .font(.caption)
            Text(verbatim: study.context.studyDesign).captionSecondary()
            Text(verbatim: study.context.population).captionSecondary()
            Text("Participants: \(study.context.participantCount)").font(.caption)
            Text(verbatim: study.context.condition).captionSecondary()
            if let endpoint = WikiTimingLabels.endpoint(study.context.endpoint) {
                Text(endpoint).captionSecondary()
            }
            if let clockOrigin = WikiTimingLabels.clockOrigin(study.context.clockOrigin) {
                HStack {
                    Text("Clock origin")
                    Spacer()
                    Text(clockOrigin)
                }
                .font(.caption)
            }
            // The label names the basis, so the row stands only for the basis it names.
            if study.context.thresholdBasis == WikiTimingLabels.individualMaximumBasis {
                HStack {
                    Text("Response threshold (% of individual maximum)")
                    Spacer()
                    Text(verbatim: wikiTimingNumber(study.context.onsetOffsetThresholdFraction * 100))
                }
                .font(.caption)
            }
            ForEach(study.points) { point in
                WikiStudyStatisticRow(
                    statistic: point, units: study.units,
                    maximum: study.points.map(\.participantRange.max).max(),
                )
            }
            Text("Active duration: onset to offset").font(.subheadline)
            WikiStudyStatisticRow(statistic: study.activeDuration, units: study.units)
            ForEach(["onset", "come_up", "peak", "offset", "total_duration", "after_effects"], id: \.self) { key in
                if let text = timingText[key] { Text(verbatim: text).captionSecondary() }
            }
            Text(verbatim: study.source.locator).captionSecondary()
            if let url = URL(string: study.source.articleUrl) {
                Link("Study article", destination: url).font(.caption)
            }
            if let url = URL(string: study.source.tableUrl) {
                Link("Study data table", destination: url).font(.caption)
            }
        }
    }
}

private func wikiTimingNumber(_ value: Double?) -> String {
    guard let value, value.isFinite else { return String(localized: "Unknown") }
    return String(format: "%.6g", value)
}

/// The API's time units are an enum; anything else reads as unknown.
private func wikiTimingUnits(_ token: String?) -> String {
    switch token {
    case "hours": String(localized: "hours")
    case "minutes": String(localized: "minutes")
    case "seconds": String(localized: "seconds")
    case "days": String(localized: "days")
    default: String(localized: "Units unknown")
    }
}

/// substance.wiki publishes these fields as machine values from a closed set.
/// A value outside the set returns nil and its row is left out, so a raw token
/// never reaches the screen.
private enum WikiTimingLabels {
    static let individualMaximumBasis = "individual_maximum_modeled_response"

    static func evidence(kind: String, evidence: String) -> LocalizedStringKey? {
        switch (kind, evidence) {
        case ("subjective_effect", "published_timing"): "Published timing"
        case ("subjective_effect", "anecdotal_timing"): "Anecdotal timing"
        case ("subjective_effect", "extrapolated_timing"): "Extrapolated, not validated"
        case ("plasma_concentration", "parameterized_model"): "Plasma model (illustrative)"
        default: nil
        }
    }

    static func confidence(_ value: String?) -> LocalizedStringKey? {
        switch value {
        case "low_moderate": "Low to moderate"
        case "low": "Low"
        case "very_low": "Very low"
        default: nil
        }
    }

    static func clockOrigin(_ value: String) -> LocalizedStringKey? {
        value == "administration" ? "Time since administration" : nil
    }

    static func endpoint(_ value: String) -> LocalizedStringKey? {
        value == "PK-PD-model-predicted any-drug-effect visual analogue scale response"
            ? "Endpoint: modeled “any drug effect” rating on a visual analog scale"
            : nil
    }
}

/// Independent bars retain the published windows; no line bridges phases or
/// missing boundaries, and no inferred start at zero is drawn.
private struct WikiTimingWindowRow: View {
    let title: LocalizedStringKey
    let window: WikiTimingWindow?
    let units: String?
    let maximum: Double?

    init(_ title: LocalizedStringKey, window: WikiTimingWindow?, units: String?, maximum: Double?) {
        self.title = title
        self.window = window
        self.units = units
        self.maximum = maximum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: "\(wikiTimingNumber(window?.start)) – \(wikiTimingNumber(window?.end)) \(wikiTimingUnits(units))")
                    .monospacedDigit()
            }
            .font(.caption)
            if let start = window?.start, let end = window?.end,
               start.isFinite, end.isFinite, start >= 0, end >= start,
               let maximum, maximum > 0 {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Theme.accent.opacity(0.5))
                        .frame(width: max(CGFloat((end - start) / maximum) * geometry.size.width, 2), height: 4)
                        .offset(x: CGFloat(start / maximum) * geometry.size.width)
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct WikiStudyStatisticRow: View {
    let statistic: WikiTimingStudy.Statistic
    let units: String
    var maximum: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = statistic.label { Text(verbatim: label).font(.caption.bold()) }
            HStack {
                Text("Mean ± SD")
                Spacer()
                Text(verbatim: "\(wikiTimingNumber(statistic.mean)) ± \(wikiTimingNumber(statistic.standardDeviation)) \(wikiTimingUnits(units))")
            }
            HStack {
                Text("Participant range")
                Spacer()
                Text(verbatim: "\(wikiTimingNumber(statistic.participantRange.min)) – \(wikiTimingNumber(statistic.participantRange.max)) \(wikiTimingUnits(units))")
            }
            if let maximum, maximum > 0,
               statistic.participantRange.min >= 0,
               statistic.participantRange.max >= statistic.participantRange.min,
               statistic.mean >= statistic.participantRange.min,
               statistic.mean <= statistic.participantRange.max {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let lower = statistic.participantRange.min / maximum
                    let upper = statistic.participantRange.max / maximum
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(0.35))
                            .frame(width: max(CGFloat(upper - lower) * width, 2), height: 4)
                            .offset(x: CGFloat(lower) * width)
                        Circle().fill(Theme.accent)
                            .frame(width: 7, height: 7)
                            .offset(x: CGFloat(statistic.mean / maximum) * width - 3.5)
                    }
                }
                .frame(height: 7)
                .accessibilityHidden(true)
                Text("Bar: participant range; dot: mean.").captionSecondary()
            }
        }
        .font(.caption)
    }
}
