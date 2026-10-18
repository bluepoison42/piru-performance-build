import Foundation
import SwiftData

/// The headless save behind the Log Dose action: the quick-log tray's commit
/// with no tray on screen. The dose is staged through ``DoseTrayModel`` so its
/// release form, isomer, identity and display snapshot derive exactly as a
/// tapped chip's do, then written through ``DoseLogService/logBatch`` with the
/// same chip curation and notification bookkeeping as the tray's Log button.
@MainActor
enum DoseIntentLogger {
    /// The app's container, set once at launch (`AppLaunch.openStore`). An
    /// intent runs in the app process with no view hierarchy to pull a
    /// context from; App Intents launch the app in the background first, so
    /// `PiruApp.init` has opened the store before `perform()` runs.
    static var modelContainer: ModelContainer?

    /// One dose as an automation describes it. Everything but the name is
    /// optional and defaults the way the tray would: the substance's default
    /// route (an ester's injection route), that route's unit, now.
    struct Request {
        /// The name the automation used: canonical, a brand, a synonym, an
        /// ester, or a custom substance's name. What it names beyond the
        /// substance (the product, the ester) stays on the dose.
        var name: String
        /// `nil` logs the dose with its amount unknown, which is what "I took
        /// some" means; the journal never invents a number.
        var amount: Double?
        var unit: String?
        var route: RouteOfAdministration?
        var time: Date?
        /// Committed onto oral doses only, like the tray's chip.
        var meal: MealState?
        var notes: String?
        var tags: [String] = []
    }

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case unknownSubstance(String)
        case storeUnavailable

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case let .unknownSubstance(name): "Piru does not know a substance named “\(name)”."
            case .storeUnavailable: "The journal could not be opened."
            }
        }
    }

    /// Save one dose to the app's journal.
    static func log(_ request: Request) async throws -> DoseEntry {
        guard let container = modelContainer else { throw Failure.storeUnavailable }
        await SubstanceStore.shared.ensureAllLoaded()
        return try await log(request, in: container.mainContext)
    }

    /// Save one dose into `context`. The catalog must be loaded.
    static func log(_ request: Request, in context: ModelContext) async throws -> DoseEntry {
        guard let named = await SubstanceLibrary.resolveNamed(request.name) else {
            throw Failure.unknownSubstance(request.name)
        }
        let staged = stage(request, as: named)
        let tags = request.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let entry = DoseEntry(
            substance: staged.substanceName,
            amount: staged.isUnknownAmount ? 0 : staged.totalAmount,
            unit: staged.unit,
            route: staged.route,
            saltForm: staged.saltForm,
            isomer: staged.isomer,
            releaseForm: staged.releaseForm,
            productName: staged.productName,
            substanceUID: staged.substanceUID,
            displayNameSnapshot: staged.displayNameSnapshot,
            timestamp: request.time ?? .now,
            notes: staged.note.isEmpty ? nil : staged.note,
            tags: tags,
            meal: staged.route == .oral ? request.meal : nil,
            isUnknownDose: staged.isUnknownAmount,
        )

        // Prior entries feed the redose and cumulative-dose checks, as the tray
        // passes them; fetched before the insert so the new dose is not in them.
        let recents = recentEntries(in: context)
        let colors = (try? context.fetch(FetchDescriptor<SubstanceColor>())) ?? []
        let fixedOrder = UserDefaults.standard.bool(forKey: QuickLogManager.fixedOrderDefaultsKey)
        // An unknown amount tapped no chip and mints none.
        let curation: [QuickLogManager.LoggedDose] = staged.isUnknownAmount ? [] : [
            QuickLogManager.LoggedDose(
                substance: staged.substanceName, route: staged.route, amount: staged.totalAmount, unit: staged.unit,
                substanceUID: staged.substanceUID, isomer: staged.isomer,
                releaseForm: staged.releaseForm, saltForm: staged.saltForm, productName: staged.productName,
            ),
        ]
        DoseLogService.shared.logBatch(
            [(entry, staged.librarySubstance)],
            colors: colors,
            in: context,
            beforeSave: {
                QuickLogManager.record(curation, fixedOrder: fixedOrder, context: context, save: false)
            },
            deferredBookkeeping: {
                DoseNotificationManager.doseLogged(entry: entry, recentEntries: recents)
            },
        )
        return entry
    }

    /// The dose as the tray would stage it from a search hit: the request's
    /// route, unit and amount over the substance's defaults, under the product
    /// or ester the name carried.
    private static func stage(_ request: Request, as named: NamedSubstance) -> StagedDose {
        let substance = named.substance
        let route = request.route ?? named.esterRoute ?? substance.defaultRoute
        let unit = request.unit?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? substance.unit(for: route, saltForm: named.saltForm)
        let tray = DoseTrayModel()
        tray.stage(
            substance: substance.name,
            route: route,
            amount: request.amount ?? 0,
            unit: unit,
            tint: nil,
            librarySubstance: substance,
            productName: named.productName,
            saltForm: named.saltForm,
        )
        var staged = tray.staged[0]
        staged.isUnknownAmount = request.amount == nil
        staged.note = request.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return staged
    }

    private static func recentEntries(in context: ModelContext) -> [DoseEntry] {
        var descriptor = FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 25
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Dialog

    /// "27 mg Concerta, oral, 9:30" — what the action says back. The title is
    /// the journal row's, the time is today's clock or a dated one.
    static func summary(for entry: DoseEntry) -> String {
        let amount = entry.isUnknownDose
            ? String(localized: "unknown amount")
            : "\(entry.amount.doseFormatted) \(entry.unit)"
        let time = Calendar.current.isDateInToday(entry.timestamp)
            ? entry.timestamp.formatted(date: .omitted, time: .shortened)
            : entry.timestamp.formatted(date: .abbreviated, time: .shortened)
        let route = String(localized: entry.route.localizedName)
        return [
            entry.isUnknownDose ? "\(DoseTitle.resolve(for: entry)) (\(amount))" : "\(amount) \(DoseTitle.resolve(for: entry))",
            route,
            time,
        ].joined(separator: ", ")
    }
}

private nonisolated extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
