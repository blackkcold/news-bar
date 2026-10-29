import SwiftUI

/// Read-only interest network: hub → topic ring → source ring.
///
/// Layout is deterministic (weight order, evenly spaced angles). Edges are
/// drawn with `Canvas`; nodes stay SwiftUI views so hover, selection,
/// accessibility and the two themes keep working. No force simulation, no 3D,
/// no chart dependency.
struct InterestNetworkCard: View {
    let model: RecommendationExplanationModel
    let palette: ExplanationPalette
    @Binding var selection: String?

    @State private var scope: InterestNetworkScope = .all

    private var english: Bool { model.language == .en }
    private var graph: InterestGraphModel { model.interestGraph }
    private var selectedTopicID: String? {
        if let selection, selection.hasPrefix("topic:") { return selection }
        return graph.topics.first?.id
    }
    private var displayed: InterestGraphModel {
        scope == .single ? graph.subgraph(topicID: selectedTopicID ?? "") : graph
    }

    var body: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Interest network" : "兴趣网络",
            subtitle: english ? "Read-only · title tags and sources" : "只读 · 标题标签与来源"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(english ? "Network scope" : "网络范围", selection: $scope) {
                    Text(english ? "Whole network" : "全图").tag(InterestNetworkScope.all)
                    Text(english ? "One topic" : "单主题").tag(InterestNetworkScope.single)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(english ? "Interest network scope" : "兴趣网络范围")

                if graph.isEmpty {
                    Text(english
                         ? "No topic tag yet. Qualified reads, bookmarks, follows or “more like this” (session preference) create tags; this graph stays empty until then."
                         : "尚无主题标签。合格阅读、收藏、关注或「更多同类」（会话偏好）后才会形成标签；此前图保持为空。")
                        .font(palette.font(10))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    InterestGraphCanvas(
                        model: displayed,
                        palette: palette,
                        language: model.language,
                        selectedTopicID: selectedTopicID,
                        onSelectTopic: { id in selection = id }
                    )
                    .frame(height: 330)

                    legend
                    textAlternative
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                legendDot(palette.accent, english ? "Hub" : "中心")
                legendDot(palette.accent.opacity(0.7), english ? "Topic" : "主题")
                legendDot(palette.border, english ? "Source" : "来源")
                Spacer(minLength: 0)
            }
            Text(english
                 ? "Line width and opacity encode weight, not causality. Dashed outline marks a node reduced by an explicit rule; negative signals are never drawn as edges."
                 : "线宽与透明度表示权重，不表示因果。虚线描边表示被「减少主题」规则标记的节点；负向信号不画成连线。")
            Text(english
                 ? "Caps: \(InterestGraphModel.topicLimit) topics, \(InterestGraphModel.sourceLimit) sources, \(InterestGraphModel.edgeLimit) links. Beyond a cap, nodes and links are cut by weight."
                 : "上限：\(InterestGraphModel.topicLimit) 个主题、\(InterestGraphModel.sourceLimit) 个来源、\(InterestGraphModel.edgeLimit) 条连线；超出时按权重截断。")
            if graph.truncatedTopics > 0 || graph.truncatedSources > 0 || graph.truncatedEdges > 0 {
                Text(english
                     ? "Hidden by weight: \(graph.truncatedTopics) topics · \(graph.truncatedSources) sources · \(graph.truncatedEdges) links."
                     : "已按权重隐藏：主题 \(graph.truncatedTopics) 个 · 来源 \(graph.truncatedSources) 个 · 连线 \(graph.truncatedEdges) 条。")
                    .foregroundStyle(palette.accent)
            }
        }
        .font(palette.font(8))
        .foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private var textAlternative: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { showText },
            set: { showText = $0 }
        )) {
            Text(displayed.textAlternative())
                .font(palette.font(9))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .textSelection(.enabled)
        } label: {
            Text(english ? "Text equivalent" : "文字等价")
                .font(palette.font(9, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
    }

    @State private var showText = false
}

enum InterestNetworkScope: Hashable {
    case all
    case single
}

/// Canvas edges plus SwiftUI nodes. The whole graphic ignores its children for
/// VoiceOver and exposes one complete text alternative instead.
struct InterestGraphCanvas: View {
    let model: InterestGraphModel
    let palette: ExplanationPalette
    let language: AppLanguage
    let selectedTopicID: String?
    let onSelectTopic: (String) -> Void

    @State private var hoveredID: String?

    private var english: Bool { language == .en }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size, model: model)
            ZStack {
                Canvas { context, _ in
                    drawEdges(context: context, geometry: geometry)
                }
                ForEach(model.topics) { topic in
                    topicNode(topic, at: geometry.point(for: topic.id) ?? .zero)
                }
                ForEach(model.sources) { source in
                    sourceNode(source, at: geometry.point(for: source.id) ?? .zero)
                }
                hubNode().position(geometry.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.textAlternative())
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Nodes

    private func hubNode() -> some View {
        Text(model.hub.label)
            .font(palette.font(10, weight: .bold))
            .foregroundStyle(palette.retro ? RetroEditorialTokens.raisedPaper : palette.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if palette.retro {
                    Rectangle().fill(RetroEditorialTokens.brick)
                } else {
                    Capsule().fill(palette.accent.opacity(0.18))
                }
            }
            .overlay {
                if palette.retro {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                } else {
                    Capsule().strokeBorder(palette.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .frame(maxWidth: 130)
    }

    private func topicNode(_ topic: InterestGraphNode, at point: CGPoint) -> some View {
        let emphasis = isEmphasized(topic.id)
        return Button {
            onSelectTopic(topic.id)
        } label: {
            VStack(spacing: 3) {
                nodeDisc(
                    diameter: diameter(topic.weight),
                    filled: topic.id == selectedTopicID,
                    suppressed: topic.isSuppressed,
                    emphasis: emphasis
                )
                Text(topic.label)
                    .font(palette.font(8, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 84)
            }
            .opacity(emphasis ? 1 : 0.42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(point)
        .onHover { hoveredID = $0 ? topic.id : (hoveredID == topic.id ? nil : hoveredID) }
        .help(tooltip(topic))
        .accessibilityLabel(accessibilityLabel(topic))
        .accessibilityAddTraits(topic.id == selectedTopicID ? [.isButton, .isSelected] : .isButton)
    }

    private func sourceNode(_ source: InterestGraphNode, at point: CGPoint) -> some View {
        let emphasis = isEmphasized(source.id)
        return VStack(spacing: 2) {
            nodeDisc(
                diameter: diameter(source.weight),
                filled: false,
                suppressed: source.isSuppressed,
                emphasis: emphasis
            )
            Text(source.label)
                .font(palette.font(7.5))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 72)
        }
        .opacity(emphasis ? 1 : 0.4)
        .position(point)
        .onHover { hoveredID = $0 ? source.id : (hoveredID == source.id ? nil : hoveredID) }
        .help(tooltip(source))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(source))
    }

    /// Three deterministic size tiers. Weight is normalized inside the ring,
    /// so a tier is a legibility device, not a second score.
    private func diameter(_ weight: Double) -> CGFloat {
        if weight >= 0.66 { return 30 }
        if weight >= 0.33 { return 24 }
        return 18
    }

    private func nodeDisc(diameter: CGFloat, filled: Bool, suppressed: Bool, emphasis: Bool) -> some View {
        Group {
            if palette.retro {
                Rectangle().fill(filled ? palette.accent : palette.cardFill)
            } else {
                Circle().fill(filled ? palette.accent : palette.cardFill)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Group {
                if palette.retro {
                    Rectangle().strokeBorder(palette.accent.opacity(0.8), lineWidth: 1)
                } else {
                    Circle().strokeBorder(palette.accent.opacity(0.8), lineWidth: 1)
                }
            }
        }
        .overlay {
            if suppressed {
                // Dashed marker only. No red edge: a reduced topic is not a
                // negative cause of anything drawn here.
                Group {
                    if palette.retro {
                        Rectangle().strokeBorder(
                            palette.secondary,
                            style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])
                        )
                    } else {
                        Circle().strokeBorder(
                            palette.secondary,
                            style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])
                        )
                    }
                }
                .padding(-2)
            }
        }
        .shadow(color: emphasis && hoveredID != nil ? palette.accent.opacity(0.25) : .clear, radius: 4)
    }

    // MARK: Edges

    private func drawEdges(context: GraphicsContext, geometry: RingGeometry) {
        for edge in model.edges {
            guard let from = geometry.point(for: edge.from),
                  let to = geometry.point(for: edge.to) else { continue }
            let emphasized: Bool
            if let selectedTopicID {
                emphasized = edge.from == selectedTopicID
            } else {
                emphasized = true
            }
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let width = 0.8 + 2.2 * edge.weight
            let opacity = (0.18 + 0.72 * edge.weight) * (emphasized ? 1 : 0.28)
            context.stroke(
                path,
                with: .color(palette.accent.opacity(opacity)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }
    }

    private func isEmphasized(_ id: String) -> Bool {
        guard let selectedTopicID else { return true }
        if id == selectedTopicID { return true }
        return model.edges.contains { $0.from == selectedTopicID && $0.to == id }
    }

    private func tooltip(_ node: InterestGraphNode) -> String {
        let weight = String(format: "%.2f", node.weight)
        switch node.kind {
        case .topic:
            let suppressed = node.isSuppressed ? (english ? " · reduced" : " · 已减少") : ""
            return english
                ? "\(node.label) · weight \(weight) · \(node.evidenceCount) evidence\(suppressed)"
                : "\(node.label) · 权重 \(weight) · 证据 \(node.evidenceCount) 条\(suppressed)"
        case .source:
            let suppressed = node.isSuppressed ? (english ? " · reduced" : " · 已减少") : ""
            return english
                ? "\(node.label) · source weight \(weight)\(suppressed)"
                : "\(node.label) · 来源权重 \(weight)\(suppressed)"
        case .hub:
            return node.label
        }
    }

    private func accessibilityLabel(_ node: InterestGraphNode) -> String {
        let weight = String(format: "%.2f", node.weight)
        if node.kind == .topic {
            let shares = node.sourceShares.isEmpty
                ? (english ? "no source links" : "暂无来源关联")
                : node.sourceShares.map { "\($0.label) \($0.count)" }.joined(separator: english ? ", " : "、")
            let suppressed = node.isSuppressed ? (english ? ", reduced by an explicit rule" : "，被减少主题规则标记") : ""
            let selected = node.id == selectedTopicID ? (english ? ", selected" : "，已选中") : ""
            return english
                ? "Topic \(node.label), weight \(weight), \(node.evidenceCount) evidence items, links to \(shares)\(suppressed)\(selected)"
                : "主题「\(node.label)」权重 \(weight)，证据 \(node.evidenceCount) 条 → \(shares)\(suppressed)\(selected)"
        }
        let suppressed = node.isSuppressed ? (english ? ", reduced by an explicit rule" : "，被减少主题规则标记") : ""
        return english
            ? "Source \(node.label), weight \(weight)\(suppressed)"
            : "来源「\(node.label)」权重 \(weight)\(suppressed)"
    }
}

/// Pure geometry: hub in the center, topics on r1, sources on r2. Angles follow
/// weight order, evenly spaced, starting at the top. Source angles are offset
/// by half a step so a source label does not sit directly on a topic spoke.
private struct RingGeometry {
    let size: CGSize
    let center: CGPoint
    let topicRadius: CGFloat
    let sourceRadius: CGFloat
    private var positions: [String: CGPoint] = [:]

    init(size: CGSize, model: InterestGraphModel) {
        self.size = size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        self.center = center
        let topicRadius = min(size.width * 0.19, size.height * 0.27)
        let sourceRadius = min(size.width * 0.38, size.height * 0.47)
        self.topicRadius = topicRadius
        self.sourceRadius = sourceRadius

        let topicStep = model.topics.isEmpty ? 0 : 2 * .pi / Double(model.topics.count)
        for (index, topic) in model.topics.enumerated() {
            let angle = -Double.pi / 2 + topicStep * Double(index)
            positions[topic.id] = CGPoint(
                x: center.x + topicRadius * CGFloat(cos(angle)),
                y: center.y + topicRadius * CGFloat(sin(angle))
            )
        }
        let sourceStep = model.sources.isEmpty ? 0 : 2 * .pi / Double(model.sources.count)
        for (index, source) in model.sources.enumerated() {
            let angle = -Double.pi / 2 + sourceStep * (Double(index) + 0.5)
            positions[source.id] = CGPoint(
                x: center.x + sourceRadius * CGFloat(cos(angle)),
                y: center.y + sourceRadius * CGFloat(sin(angle))
            )
        }
        positions[model.hub.id] = center
    }

    func point(for id: String) -> CGPoint? { positions[id] }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGVector) -> CGPoint {
        CGPoint(x: lhs.x + rhs.dx, y: lhs.y + rhs.dy)
    }
}
