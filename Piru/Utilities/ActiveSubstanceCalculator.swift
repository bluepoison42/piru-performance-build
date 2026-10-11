import SwiftUI

// MARK: - Active Substance Model

struct ActiveSubstance: Identifiable {
    let name: String
    let unit: String
    let color: Color
    let halfLifeMinutes: Double
    let totalDosed: Double
    let totalRemaining: Double
    let doses: [DoseInfo]

    /// Identity carries the unit: a substance logged in both mL and mg yields two
    /// rows (they are not addable), and `ForEach` needs them to differ.
    var id: String {
        "\(name)|\(unit)"
    }
    var eliminatedFraction: Double {
        1 - totalRemaining / totalDosed
    }

    struct DoseInfo: Identifiable {
        let id = UUID()
        let amount: Double
        let remaining: Double
        let timestamp: Date
    }
}

// MARK: - Calculator

enum ActiveSubstanceCalculator {
    /// Computes the active substances at `now` (default: the present) from dose
    /// history using a one-compartment PK model. Parameterizing `now` is what
    /// lets a body-load readout be produced for any past — or projected future —
    /// date, which the Insights "in your body over time" graph samples across a
    /// day grid. Only doses at or before `now` contribute (causality).
    static func compute(
        from entries: [DoseEntry],
        colorMap: [String: Color],
        now: Date = .now,
    ) -> [ActiveSubstance] {
        // Batch lookups: cache substance resolution so each unique name is looked up once
        var substanceCache: [String: Substance?] = [:]
        func cachedLookup(_ name: String) -> Substance? {
            let key = name.lowercased()
            if let cached = substanceCache[key] { return cached }
            let result = SubstanceLibrary.lookup(name)
            substanceCache[key] = result
            return result
        }

        // Half-life resolution goes through the shared `PKResolver`; the local cache just
        // avoids re-resolving the same name across a long dose log. Depot doses bypass
        // the cache (their half-life depends on the ester on the entry, not just the
        // name) and the acute duration below, so they read as a slow depot decay.
        var halfLifeCache: [String: Double] = [:]
        func resolveHalfLife(substance: Substance?, entry: DoseEntry, isDepot: Bool) -> Double? {
            if let depot = PKResolver.depotHalfLifeMinutes(entry: entry, isDepot: isDepot) { return depot }
            let key = entry.substance.lowercased()
            if let cached = halfLifeCache[key] { return cached }
            guard let hl = PKResolver.halfLifeMinutes(substance: substance) else { return nil }
            halfLifeCache[key] = hl
            return hl
        }

        var grouped: [String: (name: String, unit: String, halfLife: Double, doses: [ActiveSubstance.DoseInfo], totalDosed: Double, totalRemaining: Double)] = [:]
        /// Group key must carry the unit family, not just the name. Two doses of
        /// the same substance in µg/mg/g are one group (converted into whichever
        /// unit arrived first); a dose in mL or IU is a *different* quantity and
        /// gets its own group rather than being summed into a mass total.
        func unitFamily(_ unit: String) -> String {
            DoseUnit.convert(1, from: unit, to: "mg") == nil ? unit : "mass"
        }

        for entry in entries {
            let substance = cachedLookup(entry.substance)
            // Supplements/vitamins clear over days-to-weeks, so a body-load readout
            // for them ("0% eliminated · clear in 5 months") is noise, not session
            // insight. Excluded here to match their suppression on the timeline and
            // in the entry-row rail (see `from`).
            if substance?.modelsBodyLoad == false { continue }
            // A dose naming a form we don't model contributes no body-load estimate
            // either. The elimination half-life *is* a property of the molecule and
            // survives the delivery matrix — but the readout is not pure
            // elimination: `ka` below comes from the route's duration profile, i.e.
            // the immediate-release absorption limb, so a dose released over ~10 h
            // would be modelled as if it landed at once, and "clear ~12:33 PM"
            // states a time we have no basis for. Better to show nothing than
            // something misleading.
            // A per-product envelope (Concerta, Adderall XR) models the extended
            // release, so its dose contributes a body-load estimate with the right
            // absorption limb — unlike a bare unmodeled form, which we still skip.
            // No amount, no body load: 0 remaining of 0 dosed is not a fraction.
            if entry.isUnknownDose { continue }
            let productDuration = entry.productDuration
            let isDepot = PKResolver.isDepot(entry: entry)
            // A depot bypasses the unmodeled-form skip (it has no acute form to model,
            // but its slow persistence is exactly what a body-load readout is for).
            if !isDepot, productDuration == nil, entry.namesUnmodeledForm { continue }
            guard let halfLife = resolveHalfLife(substance: substance, entry: entry, isDepot: isDepot) else { continue }

            let elapsed = now.timeIntervalSince(entry.timestamp) / 60
            guard elapsed >= 0 else { continue }

            // The product envelope wins the absorption limb; otherwise the
            // route/salt/isomer-specific profile. A depot has no acute absorption
            // limb — its slow release IS the rate — so it takes the default `ka`
            // proportional to its (long) `ke`, giving a slow-rise, slow-fall shape.
            let (ke, ka) = PKResolver.rateConstants(
                halfLifeMinutes: halfLife,
                duration: isDepot ? nil : entry.applyingMeal(to: productDuration ?? substance?.resolveDuration(
                    for: entry.route, saltForm: entry.saltForm, isomer: entry.isomer,
                )),
            )
            let remaining = entry.amount * PKModel.fractionRemainingInBody(at: elapsed, ke: ke, ka: ka)
            let fraction = remaining / entry.amount

            guard fraction > 0.03 else { continue }

            let name = substance?.name ?? entry.substance
            let key = "\(name)|\(unitFamily(entry.unit))"

            if var existing = grouped[key] {
                // Express this dose in the group's established unit. Same family
                // by construction, so the conversion cannot fail; the fallback
                // keeps it honest rather than silently mixing scales.
                let amount = DoseUnit.convert(entry.amount, from: entry.unit, to: existing.unit) ?? entry.amount
                let converted = DoseUnit.convert(remaining, from: entry.unit, to: existing.unit) ?? remaining
                existing.doses.append(ActiveSubstance.DoseInfo(
                    amount: amount,
                    remaining: converted,
                    timestamp: entry.timestamp,
                ))
                existing.totalDosed += amount
                existing.totalRemaining += converted
                grouped[key] = existing
            } else {
                grouped[key] = (
                    name: name,
                    // The unit the user actually logged. Taking it from the
                    // library's `defaultUnit` instead printed "7.2 mg" under two
                    // 3.6 g doses of gabapentin — right number, wrong suffix.
                    unit: entry.unit,
                    halfLife: halfLife,
                    doses: [ActiveSubstance.DoseInfo(
                        amount: entry.amount,
                        remaining: remaining,
                        timestamp: entry.timestamp,
                    )],
                    totalDosed: entry.amount,
                    totalRemaining: remaining,
                )
            }
        }

        return grouped.map { _, info in
            let color = colorMap[info.name.lowercased()] ?? Theme.accent
            return ActiveSubstance(
                name: info.name,
                unit: info.unit,
                color: color,
                halfLifeMinutes: info.halfLife,
                totalDosed: info.totalDosed,
                totalRemaining: info.totalRemaining,
                doses: info.doses.sorted { $0.timestamp > $1.timestamp },
            )
        }
        .sorted { $0.eliminatedFraction < $1.eliminatedFraction }
    }
}
