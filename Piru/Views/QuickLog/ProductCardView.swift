import SwiftUI

/// A combination product in the quick-log list, as one card: its name, what
/// one unit (or mL) of it holds, and chips of the amounts it is taken in
/// ("1 pill", "2 pills" or "0.5 mL", "1 mL"). A chip stages the whole product,
/// one row per component under one product row in the tray.
struct ProductCardView: View, Equatable {
    let product: CustomSubstanceEntry
    /// How much of the product is staged, as a value, so the card re-renders
    /// only when its own staging changes. `nil` when none is staged.
    let stagedQuantity: Double?
    /// The amount the product's med is saved at, offered as a chip when it is
    /// not one of the standard ones.
    let medAmount: Double?
    /// Kept for staging on tap only; the body reads nothing from it.
    let tray: DoseTrayModel
    let colorLookup: [String: P3Color]

    static func == (lhs: ProductCardView, rhs: ProductCardView) -> Bool {
        lhs.product == rhs.product && lhs.stagedQuantity == rhs.stagedQuantity && lhs.medAmount == rhs.medAmount
    }

    private var chips: [Double] {
        var amounts = product.quantityChips
        if let medAmount, medAmount > 0, !amounts.contains(medAmount) {
            amounts.append(medAmount)
            amounts.sort()
        }
        return amounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: product.isLiquidCombination ? "drop" : "pills")
                    .foregroundStyle(Theme.secondaryLabel)
                    .accessibilityHidden(true)
                Text(product.resolvedDisplayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let listing = product.componentsListing {
                Text(listing)
                    .captionSecondary()
                    .lineLimit(2)
            }
            FlowLayout(spacing: Spacing.sm) {
                ForEach(chips, id: \.self) { amount in
                    chip(amount)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(cornerRadius: 20)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ amount: Double) -> some View {
        let isStaged = stagedQuantity.map { abs($0 - amount) < 0.0001 } ?? false
        let label = product.quantityLabel(amount)
        return Button {
            withAnimation(.snappy) {
                tray.stage(product: product, amount: amount, colorLookup: colorLookup)
            }
        } label: {
            Text(verbatim: label)
                .font(OneRowChipMetrics.font)
                .padding(.horizontal, OneRowChipMetrics.horizontalPadding)
                .padding(.vertical, OneRowChipMetrics.verticalPadding)
                .background(isStaged ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(Theme.Opacity.tint)))
                .foregroundStyle(isStaged ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.accent))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(label), \(product.resolvedDisplayName)"))
        .accessibilityAddTraits(isStaged ? [.isSelected] : [])
    }
}
