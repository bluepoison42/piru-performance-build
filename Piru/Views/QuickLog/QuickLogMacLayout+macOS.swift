import SwiftUI

// MARK: - Log Window (macOS)

/// The Log sheet on macOS: one window in two panes, the picker (search, the
/// meds, favorites and recents) beside the staged tray and its Record button.
///
/// iOS layers a detented dock over a full-screen card list; a Mac sheet has no
/// detents and no room problem, so both surfaces sit side by side instead.
/// State, data loading and the commit all stay on `QuickLogView`; this view
/// owns only the layout and the sheets the iOS dock would otherwise present
/// (the custom-substance form, the Edit sheet, nested navigator sheets).
struct QuickLogMacLayout: View {
    var tray: DoseTrayModel
    var content: QuickLogContentModel
    @Binding var searchText: String
    @Binding var showCustomForm: Bool
    @Binding var showEditSheet: Bool
    let onCommit: () -> Void

    @Environment(\.appNavigator) private var navigator

    @State private var confirmingDiscard = false
    @State private var pendingCustomPrefill: EntryPrefillPayload?

    var body: some View {
        HStack(spacing: 0) {
            QuickLogMacPicker(
                tray: tray,
                content: content,
                searchText: $searchText,
                onCreateCustom: { showCustomForm = true },
            )
            .frame(minWidth: Metrics.pickerMinWidth, maxWidth: .infinity)

            Divider()

            QuickLogMacTray(tray: tray, content: content, onCommit: onCommit)
                .frame(width: Metrics.trayWidth)
        }
        .frame(
            minWidth: Metrics.pickerMinWidth + Metrics.trayWidth,
            idealWidth: Metrics.idealWidth,
            minHeight: Metrics.minHeight,
            idealHeight: Metrics.idealHeight,
        )
        .skinBackdrop()
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: close)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showEditSheet = true
                }
                .accessibilityLabel("Edit routines and favorites")
            }
        }
        .confirmationDialog("Discard Entries", isPresented: $confirmingDiscard) {
            Button("Discard Entries", role: .destructive) {
                navigator.dismiss()
            }
        }
        .sheet(isPresented: $showCustomForm, onDismiss: onCustomFormDismiss) {
            CustomSubstanceFormView(initialName: searchText.trimmingCharacters(in: .whitespaces)) { saved in
                pendingCustomPrefill = EntryPrefillPayload(
                    substance: saved.name,
                    route: saved.defaultRoute,
                    unit: saved.unit,
                )
            }
            .macSheetSize()
        }
        .sheet(isPresented: $showEditSheet) {
            QuickLogEditSheet()
                .macSheetSize()
        }
        // Navigator sheets launched from quick log (Manage Routines, Edit
        // Routine…) stack on this window: the cover branch of the sheet stack
        // does not wrap the next layer, so they present here.
        .hostsNestedNavigatorSheets(navigator)
    }

    /// Staged doses are work in progress, so leaving with any asks first.
    private func close() {
        if tray.isEmpty {
            navigator.dismiss()
        } else {
            confirmingDiscard = true
        }
    }

    private func onCustomFormDismiss() {
        guard let prefill = pendingCustomPrefill else { return }
        pendingCustomPrefill = nil
        withAnimation(.snappy) {
            tray.stageDraft(
                substance: prefill.substance,
                route: prefill.route,
                unit: prefill.unit,
                tint: SubstancePalette.tint(for: prefill.substance, tintMap: content.cachedColorLookup),
                librarySubstance: SubstanceLibrary.lookup(prefill.substance.lowercased()),
            )
            searchText = ""
        }
    }

    private enum Metrics {
        static let pickerMinWidth: CGFloat = 380
        static let trayWidth: CGFloat = 380
        static let idealWidth: CGFloat = 880
        static let minHeight: CGFloat = 420
        static let idealHeight: CGFloat = 680
    }
}

private extension View {
    /// A `List` or `Form` has no height of its own, and a macOS sheet sizes to
    /// its content, so without a frame these sheets open as a bare title bar.
    func macSheetSize() -> some View {
        frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 620)
    }
}

// MARK: - Picker Pane

/// The left pane: the search field over either the card list (meds,
/// favorites, recents) or, while there is a query, the ranked results.
private struct QuickLogMacPicker: View {
    var tray: DoseTrayModel
    @Bindable var content: QuickLogContentModel
    @Binding var searchText: String
    let onCreateCustom: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DockSearchBar(
                searchText: $searchText,
                searchActive: false,
                searchFocused: $searchFocused,
                onCancel: { searchText = "" },
            )
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)

            ScrollView {
                if searchText.isEmpty {
                    QuickLogCardList(content: content, tray: tray)
                } else {
                    DockMiddleContent(
                        isBare: false,
                        searchActive: true,
                        searchText: searchText,
                        tray: tray,
                        content: content,
                        families: content.browseFamilies,
                        selectedFamilyID: $content.selectedFamilyID,
                        browseResults: $content.browseResults,
                        unrevealedItemIDs: [],
                        awaitingBareCollapse: false,
                        showsStagedBasket: false,
                        onCreateCustom: onCreateCustom,
                        onDidStage: finishStagingFromSearch,
                    )
                }
            }
            .contentMargins(.horizontal, Spacing.xxl, for: .scrollContent)
            .contentMargins(.bottom, Spacing.xl, for: .scrollContent)
        }
        .onKeyPress(.escape) {
            guard !searchText.isEmpty else { return .ignored }
            searchText = ""
            return .handled
        }
    }

    /// A hit was staged: clear the query so the cards return, and open the
    /// staged editors — the same landing the iOS dock settles on.
    private func finishStagingFromSearch() {
        tray.expandedItemIDs = Set(tray.staged.map(\.id))
        withAnimation(.snappy) { searchText = "" }
    }
}

// MARK: - Tray Pane

/// The right pane: the staged doses, each expanding inline into its editor,
/// over the warnings, the When/Tags/Location chips and the Record button.
private struct QuickLogMacTray: View {
    var tray: DoseTrayModel
    var content: QuickLogContentModel
    let onCommit: () -> Void

    var body: some View {
        if tray.isEmpty {
            ContentUnavailableView(
                "Nothing Staged",
                systemImage: "tray",
                description: Text("Choose a dose on the left, or search for a substance."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                TrayStagedListCard(model: tray)
            }
            .contentMargins(Spacing.xl, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                TrayCommitBar(model: tray, content: content, onCommit: onCommit)
                    // The When/Location chips are menus: AppKit would draw its
                    // own bezel and chevron around the chip's capsule.
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .padding(Spacing.xl)
            }
        }
    }
}
