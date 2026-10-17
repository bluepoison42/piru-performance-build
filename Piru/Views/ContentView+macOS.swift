import SwiftData
import SwiftUI

// MARK: - Sidebar Window

/// The macOS window: the user's tab bar as a sidebar, then a separator, then
/// the actions the iOS tab bar's bottom accessory carries — the live session,
/// the dock's shortcut slots and "Record an entry". The detail column hosts the
/// selected tab's own navigation stack, so every tab keeps its push path
/// exactly as it does on iOS.
///
/// Reads the same `TabLayoutStore` layout and `AppNavigator` state as
/// `MainTabView`, so Settings ▸ Tabs, deep links and `navigator.open(_:home:)`
/// land identically on both platforms.
struct MacSidebarView: View {
    @Environment(\.appNavigator) private var navigator

    @State private var searchScope: SearchTabScope = .library
    @State private var searchText = ""
    @State private var librarySearchText = ""
    /// Due meds and the accessory's center label, refreshed off the body.
    @State private var dockStatus = MacDockStatus()

    var body: some View {
        let layout = TabLayoutStore.shared.layout
        NavigationSplitView {
            List(selection: selection) {
                ForEach(layout.tabs) { tab in
                    tabLabel(tab).tag(tab)
                }
                if layout.showsSearch {
                    tabLabel(.search).tag(TabID.search)
                }

                Divider()

                MacSidebarActions(status: dockStatus)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .background { MacDockStatusUpdater(status: dockStatus) }
        } detail: {
            MacSidebarDetail(
                tab: navigator.selectedTab,
                searchScope: $searchScope,
                searchText: $searchText,
                librarySearchText: $librarySearchText,
            )
        }
        .onChange(of: navigator.selectedTab) { oldValue, newValue in
            if newValue == .search {
                searchScope = (oldValue == .journal) ? .journal : .library
            }
            searchText = ""
            librarySearchText = ""
        }
        // Settings ▸ Tabs and a backup restore both land here.
        .onChange(of: layout.visible) { _, visible in
            navigator.reconcile(visible: visible)
        }
    }

    /// The list's selection is optional; the navigator's tab never is, so a
    /// deselect (clicking empty space) keeps the current tab.
    private var selection: Binding<TabID?> {
        Binding(
            get: { navigator.selectedTab },
            set: { newValue in
                guard let newValue else { return }
                navigator.selectedTab = newValue
            },
        )
    }

    private func tabLabel(_ tab: TabID) -> some View {
        Label {
            TabLayoutStore.shared.label(for: tab)
        } icon: {
            Image(systemName: tab.systemImage)
        }
    }
}

/// The selected tab's navigation stack. Keyed by the tab so switching swaps
/// the whole stack (and its path binding) rather than reusing one stack across
/// tabs.
private struct MacSidebarDetail: View {
    let tab: TabID
    @Binding var searchScope: SearchTabScope
    @Binding var searchText: String
    @Binding var librarySearchText: String

    @Environment(\.appNavigator) private var navigator

    var body: some View {
        NavigationStack(path: navigator.pathBinding(for: tab)) {
            root.withAppDestinations()
        }
        .id(tab)
    }

    @ViewBuilder
    private var root: some View {
        if tab == .search {
            SearchView(scope: $searchScope, searchText: $searchText)
        } else {
            TabRootView(tab: tab, searchText: $searchText, librarySearchText: $librarySearchText)
        }
    }
}

// MARK: - Dock Status

/// What the accessory's idle face derives — the due meds behind the "+" badge
/// and the center label — held for the sidebar's "Record an entry" row.
@Observable @MainActor
private final class MacDockStatus {
    var context = DockLabelContext()

    var dueCount: Int {
        context.dueMedNames.count
    }

    /// The accessory's center label, or nil when it has nothing to say.
    func label(_ labels: [DockLabel]) -> String? {
        let resolved = DockLabel.resolve(labels, in: context)
        return resolved == DockLabel.unavailable ? nil : resolved
    }
}

/// Recomputes ``MacDockStatus`` once a minute, whenever the meds list changes
/// and after every logged dose — the accessory label's own cadence. A
/// zero-size leaf, so its query and clock never re-run the sidebar body.
private struct MacDockStatusUpdater: View {
    let status: MacDockStatus

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DailyDoseItem.sortOrder) private var items: [DailyDoseItem]
    @State private var now = Date.now

    var body: some View {
        Color.clear
            .task(id: recomputeKey) {
                await SubstanceStore.shared.ensureAllLoaded()
                guard !Task.isCancelled else { return }
                status.context = DockLabelContext.derive(items: items, in: modelContext, now: now)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = .now
                }
            }
    }

    private var recomputeKey: String {
        "\(Int(now.timeIntervalSinceReferenceDate / 60))|\(items.count)|\(DoseLogService.shared.revision)"
    }
}

// MARK: - Accessory Actions

/// The rows below the separator, in the accessory's own order: the live
/// session (its pill face), the shortcut slots, then "Record an entry" (its "+").
private struct MacSidebarActions: View {
    let status: MacDockStatus

    @Environment(\.appNavigator) private var navigator
    @Environment(\.modelContext) private var modelContext
    @State private var preferences = DockPreferences.shared

    var body: some View {
        if ActiveSessionManager.shared.hasActiveSession {
            MacSidebarRow(action: showSession) {
                MacSessionRowContent()
            }
            .accessibilityLabel(Text("Session"))
        }

        ForEach(preferences.shortcuts) { shortcut in
            MacShortcutRow(shortcut: shortcut)
        }

        MacSidebarRow(action: record) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Record an entry")
                    if let label = status.label(preferences.labels) {
                        Text(verbatim: label)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "plus")
            }
        }
        .badge(status.dueCount)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityInputLabels([Text("Record an entry"), Text("Record"), Text("Add")])
    }

    private func record() {
        OnboardingTips.logDoseInvoked()
        guard navigator.sheetStack.isEmpty else { return }
        navigator.present(.quickLog(routine: nil))
    }

    private func showSession() {
        guard navigator.sheetStack.isEmpty else { return }
        navigator.revealOrPresentSessionDetail(currentSessionID: mostRecentSessionID(in: modelContext))
    }
}

/// A sidebar row that acts rather than selects: the whole row is the button,
/// drawn like the tab rows above it.
private struct MacSidebarRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The accessory's live-session pill as a sidebar row: the mini timeline, the
/// substance names and elapsed/remaining times, ticking once a minute.
private struct MacSessionRowContent: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            SessionAccessoryInfo(
                states: ActiveSessionManager.shared.activeSubstanceStates,
                currentTime: context.date,
                placement: nil,
            )
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// One dock shortcut slot as a sidebar row. Fixed kinds show their symbol and
/// title; a favorite shows its substance's color with its initial — the same
/// identity the accessory slot and the Log sheet's cards carry.
private struct MacShortcutRow: View {
    let shortcut: DockShortcut

    @Environment(\.appNavigator) private var navigator
    @Environment(\.modelContext) private var modelContext
    @Query private var substanceColors: [SubstanceColor]
    /// A favorite's display name, resolved once the substance cache is warm.
    @State private var favoriteTitle: String?

    var body: some View {
        MacSidebarRow(action: { shortcut.perform(navigator: navigator, modelContext: modelContext) }) {
            Label {
                Text(verbatim: title)
            } icon: {
                icon
            }
        }
        .disabled(shortcut.requiresActiveSession && !ActiveSessionManager.shared.hasActiveSession)
        .task(id: shortcut) {
            guard let substance = shortcut.favoriteSubstance else { return }
            await SubstanceStore.shared.ensureAllLoaded()
            guard !Task.isCancelled else { return }
            favoriteTitle = CustomSubstanceStore.shared.displayName(for: substance)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let substance = shortcut.favoriteSubstance {
            Text(substance.prefix(1).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint(for: substance)?.color ?? .gray, in: Circle())
        } else {
            Image(systemName: shortcut.systemImage)
        }
    }

    private var title: String {
        if let substance = shortcut.favoriteSubstance {
            return favoriteTitle ?? substance
        }
        return shortcut.fixedTitle.map { String(localized: $0) } ?? ""
    }

    private func tint(for substance: String) -> P3Color? {
        Array(substanceColors).tintMap[substance.lowercased()]
    }
}
