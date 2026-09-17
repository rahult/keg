import SwiftUI

/// Layered layout for a compose service dependency graph.
///
/// Levels follow `depends_on`: a service with no dependencies sits at
/// level 0. Columns are then reversed for display so entry-point services
/// (web) appear on the left and leaf dependencies (db) on the right —
/// arrows point at what a service depends on, which for a typical web
/// app is also the direction requests flow.
///
/// The layout is a pure function so level assignment, ordering, and
/// geometry can be unit tested without any AppKit involvement.
struct ComposeGraphLayout: Equatable {
    struct Node: Identifiable, Equatable {
        let id: String
        let image: String?
        let dependsOn: [String]
        /// 0 = leaf dependency (db), increasing toward entry points (web).
        let level: Int
        /// Display column — the inverse of level so traffic reads left→right.
        let column: Int
        let row: Int
        let center: CGPoint
    }

    struct Edge: Equatable {
        let from: String
        let to: String
    }

    struct Geometry: Equatable {
        static let nodeWidth: CGFloat = 136
        static let nodeHeight: CGFloat = 46
        static let columnGap: CGFloat = 72
        static let rowGap: CGFloat = 20

        let size: CGSize
        let nodes: [Node]
        let edges: [Edge]

        func node(named name: String) -> Node? {
            nodes.first { $0.id == name }
        }
    }

    /// Number of display columns (= deepest dependency chain).
    let columns: Int
    let geometry: Geometry

    /// Builds the layout from a plan's services, in plan order (which the
    /// orchestrator already emits topologically). Defensive against cycles
    /// and dangling references: back-edges are ignored for levelling and
    /// edges to unknown services are dropped, so a malformed file can never
    /// hang layout or draw an edge into space.
    static func build(from services: [ComposeOrchestrator.ComposePlan.PlannedService]) -> ComposeGraphLayout {
        let known = Set(services.map(\.name))
        let depsByService: [String: [String]] = Dictionary(
            uniqueKeysWithValues: services.map { service in
                var seen = Set<String>()
                let deps = service.dependsOn.filter { known.contains($0) && seen.insert($0).inserted }
                return (service.name, deps)
            }
        )

        var levels: [String: Int] = [:]
        var visiting = Set<String>()

        func level(of name: String) -> Int {
            if let cached = levels[name] { return cached }
            guard visiting.insert(name).inserted else { return 0 } // cycle: break the back edge
            defer { visiting.remove(name) }
            let value = (depsByService[name] ?? []).map(level(of:)).max().map { $0 + 1 } ?? 0
            levels[name] = value
            return value
        }
        for service in services { _ = level(of: service.name) }

        let maxLevel = levels.values.max() ?? 0
        let columnCount = maxLevel + 1

        // Row order within a column is stable by first appearance, so the
        // graph doesn't reshuffle when an unrelated service is added.
        var rowsPerColumn = Array(repeating: 0, count: columnCount)
        for service in services {
            let column = maxLevel - (levels[service.name] ?? 0)
            rowsPerColumn[column] += 1
        }

        let tallestColumn = rowsPerColumn.max() ?? 1
        let size = CGSize(
            width: CGFloat(columnCount) * Geometry.nodeWidth + CGFloat(maxLevel) * Geometry.columnGap,
            height: CGFloat(tallestColumn) * Geometry.nodeHeight + CGFloat(max(tallestColumn - 1, 0)) * Geometry.rowGap
        )

        func position(column: Int, row: Int) -> CGPoint {
            let x = CGFloat(column) * (Geometry.nodeWidth + Geometry.columnGap) + Geometry.nodeWidth / 2
            let count = rowsPerColumn[column]
            let columnHeight = CGFloat(count) * Geometry.nodeHeight + CGFloat(max(count - 1, 0)) * Geometry.rowGap
            let topOffset = (size.height - columnHeight) / 2
            let y = topOffset + CGFloat(row) * (Geometry.nodeHeight + Geometry.rowGap) + Geometry.nodeHeight / 2
            return CGPoint(x: x, y: y)
        }

        var rowCursor = Array(repeating: 0, count: columnCount)
        var nodes: [Node] = []
        for service in services {
            let level = levels[service.name] ?? 0
            let column = maxLevel - level
            let row = rowCursor[column]
            rowCursor[column] += 1
            nodes.append(Node(
                id: service.name,
                image: service.image,
                dependsOn: depsByService[service.name] ?? [],
                level: level,
                column: column,
                row: row,
                center: position(column: column, row: row)
            ))
        }

        var edges: [Edge] = []
        for node in nodes {
            for dep in node.dependsOn {
                edges.append(Edge(from: node.id, to: dep))
            }
        }

        return ComposeGraphLayout(
            columns: columnCount,
            geometry: Geometry(size: size, nodes: nodes, edges: edges)
        )
    }
}

/// Interactive dependency graph for the Compose screen. Edges render in a
/// Canvas; nodes are real buttons positioned over it so they are tappable,
/// hoverable, right-clickable, and exposed to Accessibility.
struct ComposeGraphView: View {
    let plan: ComposeOrchestrator.ComposePlan
    /// service name → "running" / "stopped" / …; absent = not created.
    let states: [String: String]
    @Binding var selectedService: String?
    var onViewLogs: (String) -> Void = { _ in }
    var onRestart: (String) -> Void = { _ in }

    var body: some View {
        let graph = ComposeGraphLayout.build(from: plan.services).geometry

        ScrollView(.horizontal, showsIndicators: false) {
            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges {
                        drawEdge(edge, in: &context, graph: graph)
                    }
                }
                .frame(width: graph.size.width, height: graph.size.height)
                .accessibilityHidden(true)

                ForEach(graph.nodes) { node in
                    nodeCard(node)
                        .position(node.center)
                }
            }
            .frame(width: graph.size.width, height: graph.size.height)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Service dependency graph")
    }

    // MARK: - Nodes

    private func isSelected(_ node: ComposeGraphLayout.Node) -> Bool {
        selectedService == node.id
    }

    /// True when an edge should be emphasized because one of its endpoints
    /// is selected — tracing a service highlights exactly what it talks to.
    private func touchesSelection(_ edge: ComposeGraphLayout.Edge) -> Bool {
        selectedService == edge.from || selectedService == edge.to
    }

    @ViewBuilder
    private func nodeCard(_ node: ComposeGraphLayout.Node) -> some View {
        let state = states[node.id]
        Button {
            selectedService = isSelected(node) ? nil : node.id
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    stateDot(state)
                    Text(node.id)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(node.image ?? "built from Dockerfile")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }
            .padding(.vertical, 5)
            .frame(width: ComposeGraphLayout.Geometry.nodeWidth, height: ComposeGraphLayout.Geometry.nodeHeight)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected(node) ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected(node) ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected(node) ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("View Logs") { onViewLogs(node.id) }
            Button("Restart") { onRestart(node.id) }
            Divider()
            Button("Copy Service Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
            }
        }
        .help(summary(of: node, state: state))
        .accessibilityLabel(summary(of: node, state: state))
    }

    private func summary(of node: ComposeGraphLayout.Node, state: String?) -> String {
        var parts = [node.id, state ?? "not created"]
        if !node.dependsOn.isEmpty {
            parts.append("depends on \(node.dependsOn.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    /// Dot color mirrors StatusBadge semantics so the graph and the table
    /// tell the same story. Nil state (service never started) renders hollow.
    @ViewBuilder
    private func stateDot(_ state: String?) -> some View {
        if let state {
            Circle()
                .fill(state.lowercased() == "running" ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: - Edges

    private func drawEdge(
        _ edge: ComposeGraphLayout.Edge,
        in context: inout GraphicsContext,
        graph: ComposeGraphLayout.Geometry
    ) {
        guard let from = graph.node(named: edge.from),
              let to = graph.node(named: edge.to) else { return }

        let start = CGPoint(x: from.center.x + ComposeGraphLayout.Geometry.nodeWidth / 2, y: from.center.y)
        let end = CGPoint(x: to.center.x - ComposeGraphLayout.Geometry.nodeWidth / 2, y: to.center.y)
        let midX = (start.x + end.x) / 2
        let path = Path { p in
            p.move(to: start)
            p.addCurve(
                to: end,
                control1: CGPoint(x: midX, y: start.y),
                control2: CGPoint(x: midX, y: end.y)
            )
        }

        let emphasized = touchesSelection(edge)
        let color = emphasized ? Color.accentColor : Color(nsColor: .separatorColor)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: emphasized ? 1.8 : 1.2))

        // Arrowhead at the dependency's left edge, pointing right.
        let arrow = Path { p in
            p.move(to: CGPoint(x: end.x, y: end.y))
            p.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
            p.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
            p.closeSubpath()
        }
        context.fill(arrow, with: .color(color))
    }
}
