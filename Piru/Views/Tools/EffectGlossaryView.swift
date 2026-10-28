import SwiftUI

/// **Every subjective effect a note can name**, grouped under its rollup and
/// each shown with its definition: the same vocabulary, search and rows the
/// session-note descriptor picker uses, read here as a reference. The rollup
/// leads its own section, since it is an effect of its own ("body load").
struct EffectGlossaryView: View {
    @State private var query = ""
    @State private var ontology = SubjectiveEffectOntology.shared

    /// More than the picker's 30: a reader scanning a broad word ("visual")
    /// wants the whole family, and nothing here is being chosen.
    private static let searchLimit = 120

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(ontology.rollups) { rollup in
                    Section {
                        DescriptorHitLabel(hit: SubjectiveEffectHit(concept: rollup, matchedAlias: nil))
                        ForEach(ontology.atomics(under: rollup)) { concept in
                            DescriptorHitLabel(hit: SubjectiveEffectHit(concept: concept, matchedAlias: nil))
                        }
                    } header: {
                        Text(verbatim: rollup.name.capitalizedFirst)
                    }
                    .listRowBackground(CardBackground())
                }
            } else {
                let groups = ontology.searchGrouped(query, limit: Self.searchLimit)
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.hits) { hit in
                                DescriptorHitLabel(hit: hit)
                            }
                        } header: {
                            Text(verbatim: group.title.capitalizedFirst)
                        }
                        .listRowBackground(CardBackground())
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .themedPage()
        .searchable(text: $query, placement: .automatic, prompt: Text("Search effects"))
        .task { ontology.load() }
    }
}
