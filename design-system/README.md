# Piru design system — color

Piru separates status colors, multistep scales, and substance identity colors. This folder generates their Display P3 asset catalogs, previews the palettes, and checks contrast with Oklab and WCAG calculations.

<details>
<summary>Color systems and contrast reference</summary>

## The three systems

The three layers share one namespace:

| Layer | What it is | Meaning-bearing? | Chosen by | May be small text? |
|---|---|---|---|---|
| **L1 status** | `danger` `caution` `success` `info` | yes, closed set | designer | **yes** — that is its job |
| **L2 scales** | routes (11), dose levels, phases, severity, adherence | yes, multi-valued | designer | yes, if tuned |
| **L3 identity** | per-substance color | **no** | user, or an FNV-1a hash of the name | **never** |

1. **Name tokens by role, never hue:** `semantic/caution/text`.
2. **Keep `text` and `accent` separate, always.** Text needs contrast; accent carries the vivid mark. `fill` is derived from `accent` at 0.10 alpha and is never authored.
3. **L3 identity never renders as small text.** Use dots, rings, bar fills, swatches, or strokes ≥2pt. See [the measurements](color/color-system.md).
4. **Distinguish layers by shape.** Status uses an icon in a filled pill; identity uses a bare dot or ring; encoding uses a labeled pill. Respect `.accessibilityDifferentiateWithoutColor` with icons, patterns, or strokes.

## Verifying and changing colors

Run the calculations and preview:

```bash
cd design-system/color
python3 colorimetry.py                                 # self-tests vs published WCAG + Oklab values
python3 make_preview.py && open palette-preview.html   # render the palette (P3, Safari)
```

To change a semantic color:

1. Edit `palette-L1.json` (ship the `*_p3` components; the hexes are sRGB display-equivalents for
   reading only — all eight are *outside* sRGB).
2. Regenerate the catalog:
   ```bash
   python3 generate_colorsets.py palette-generator-input.json --out ../../Shared/Assets.xcassets
   ```
3. Run `PiruTests/ColorContrastTests` — it verifies the tokens **at runtime**, after catalog
   resolution, at shipped precision.

### Using a token in code

**Xcode generates the accessors.** With
`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`
(`project.pbxproj:395,463`), the catalog itself produces nested, compile-time checked symbols:

```swift
Color.Semantic.Caution.text     // SwiftUI
UIColor.Semantic.Info.text      // UIKit
.Semantic.Success.accent        // as a ColorResource
```

## The contrast gate

`PiruTests/ColorContrastTests.swift` checks resolved tokens at shipped precision. Known gaps have two-sided expectations: regression fails, and clearing the threshold also fails so the check can be promoted.

Pinned gaps include dark-mode route pills (2.60–3.93), non-caution status tiers rendering raw orange and red as text, and `Theme.secondaryLabel` at 3.89.

## Layout

```
design-system/
└── color/
    ├── colorimetry.py             Oklab/WCAG math + self-tests (root CLAUDE.md points here)
    ├── generate_colorsets.py      palette JSON → Assets.xcassets (emits display-p3 only)
    ├── build_l2_scales.py         generates the multi-step scales
    ├── build_generator_input.py   assembles generator input from L1 + scales
    ├── make_preview.py            renders palette-preview.html
    ├── palette-L1.json            the eight semantic seeds — edit this to change a color
    ├── palette-L2.json            derived multi-step scales
    ├── scales.json / inventory.json / sampled.json
    ├── color-system.md            palette structure
    ├── semantic-roles.md          what each role means, and when to use it
    ├── scales.md                  the multi-step scales
    └── *.html                     tuning sheets (open in Safari for true P3)
```

</details>
