import SwiftUI

/// Big-number stat card used at the top of detail panes and across the
/// dashboard. Three sizes:
///   .compact    — sidebar chips
///   .standard   — default, used in detail stat rows
///   .prominent  — large dashboard tiles
struct StatCard: View {
    enum Size { case compact, standard, prominent }

    let icon: String?
    let value: String
    let label: String
    let tint: Color
    let size: Size

    init(icon: String? = nil, value: String, label: String, tint: Color = .accentColor, size: Size = .standard) {
        self.icon = icon
        self.value = value
        self.label = label
        self.tint = tint
        self.size = size
    }

    var body: some View {
        HStack(alignment: .center, spacing: iconSpacing) {
            if let icon {
                Image(systemName: icon)
                    .font(iconFont)
                    .foregroundStyle(tint)
                    .frame(width: iconFrame, height: iconFrame)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(padding)
        .background(backgroundMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var padding: EdgeInsets {
        switch size {
        case .compact:   return EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        case .standard:  return EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        case .prominent: return EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        }
    }
    private var iconSpacing: CGFloat {
        switch size { case .compact: 6; case .standard: 10; case .prominent: 12 }
    }
    private var iconFrame: CGFloat {
        switch size { case .compact: 22; case .standard: 28; case .prominent: 36 }
    }
    private var iconFont: Font {
        switch size { case .compact: .caption; case .standard: .body; case .prominent: .title2 }
    }
    private var valueFont: Font {
        switch size {
        case .compact:   .subheadline.weight(.semibold).monospacedDigit()
        case .standard:  .title3.weight(.semibold).monospacedDigit()
        case .prominent: .title.weight(.semibold).monospacedDigit()
        }
    }
    private var labelFont: Font {
        switch size { case .compact: .caption2; case .standard: .caption; case .prominent: .callout }
    }

    private var backgroundMaterial: AnyShapeStyle {
        switch size {
        case .compact:   AnyShapeStyle(.thinMaterial)
        case .standard:  AnyShapeStyle(.regularMaterial)
        case .prominent: AnyShapeStyle(.regularMaterial)
        }
    }
}
