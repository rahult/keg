import SwiftUI

/// Tiny row-level sparkline: the shape matters more than axis precision —
/// spikes should read at a glance next to the number (Modal-style rows).
struct InlineSparkline: View {
    let values: [Double]
    var color: Color = .blue

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else {
                // One sample so far: a single dot beats an empty box.
                if values.count == 1 {
                    let dot = CGRect(x: size.width / 2 - 1, y: size.height / 2 - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.5)))
                }
                return
            }
            let peak = max(values.max() ?? 0, 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let y = size.height - 1 - CGFloat(value / peak) * (size.height - 2)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}
