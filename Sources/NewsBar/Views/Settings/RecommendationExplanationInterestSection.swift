import SwiftUI

struct ExplanationInterestsSection: View {
    let model: RecommendationExplanationModel
    let palette: ExplanationPalette
    @Binding var selection: String?
    var wide = false

    private var english: Bool { model.language == .en }
    private var selectedID: String? { selection ?? model.dimensions.first?.id }

    var body: some View {
        // Wide sheets get a two-column reading layout; narrow ones stay a single
        // scrolling column, driven by one measured width from the root.
        Group {
            if wide {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        groupsView
                        mergeNoteView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        connectionView
                        weightNoteView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    groupsView
                    mergeNoteView
                    connectionView
                    weightNoteView
                }
            }
        }
    }

    @ViewBuilder
    private var groupsView: some View {
        if let retainedProfileNote = model.retainedProfileNote {
            ExplanationNote(text: retainedProfileNote, palette: palette, systemImage: "lock.rotation")
        }
        if let emptyReason = model.emptyReason {
            ExplanationNote(text: emptyReason, palette: palette, systemImage: "circle.dashed")
        }
        ForEach(model.groups) { group in
            groupCard(group)
        }
    }

    @ViewBuilder
    private var mergeNoteView: some View {
        if let mergeNote = model.followMergeNote {
            ExplanationNote(text: mergeNote, palette: palette, systemImage: "link")
        }
    }

    @ViewBuilder
    private var connectionView: some View {
        if let id = selectedID, let connections = model.connections(for: id) {
            ExplanationConnectionCard(connections: connections, palette: palette, language: model.language)
        } else {
            ExplanationCard(palette: palette) {
                ExplanationNote(
                    text: english ? "Select a tag to inspect its evidence links." : "选择一个标签以查看证据关联。",
                    palette: palette,
                    systemImage: "cursorarrow.click"
                )
            }
        }
    }

    private var weightNoteView: some View {
        ExplanationNote(text: model.weightNote, palette: palette, systemImage: "scalemass")
    }

    private func groupCard(_ group: RecommendationExplanationGroup) -> some View {
        ExplanationCard(
            palette: palette,
            title: group.title,
            subtitle: english ? "\(group.dimensions.count)" : "\(group.dimensions.count) 项"
        ) {
            if group.dimensions.isEmpty {
                Text(group.emptyText)
                    .font(palette.font(10))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(group.dimensions) { dimension in
                        dimensionRow(dimension)
                    }
                }
            }
        }
    }

    private func dimensionRow(_ dimension: RecommendationExplanationDimension) -> some View {
        let isSelected = dimension.id == selectedID
        return Button {
            selection = dimension.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dimension.label)
                        .font(palette.font(11, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    if dimension.isManual {
                        chip(english ? "literal" : "字面")
                    }
                    ForEach(Array(dimension.manualFollowKeywords.prefix(2)), id: \.self) { keyword in
                        chip(english ? "follow: \(keyword)" : "关注：\(keyword)")
                    }
                    if dimension.isReduced {
                        chip(english ? "reduced" : "已减少")
                    }
                    if dimension.isSessionOnly {
                        chip(english ? "session/recent" : "会话/近期")
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "%.2f", dimension.longTerm))
                        .font(palette.mono(9, weight: .semibold))
                        .foregroundStyle(dimension.longTerm < 0 ? .red : palette.ink)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(palette.font(9))
                            .foregroundStyle(palette.accent)
                    }
                }
                weightBar(dimension.relativeWeight)
                HStack(spacing: 8) {
                    Text(english ? "\(dimension.evidenceCount) recent evidence" : "最近 \(dimension.evidenceCount) 条证据")
                    Text(english
                         ? String(format: "long %.2f · short %.2f", dimension.longTerm, dimension.shortTerm)
                         : String(format: "长期 %.2f · 近期 %.2f", dimension.longTerm, dimension.shortTerm))
                    Spacer(minLength: 0)
                }
                .font(palette.font(8))
                .foregroundStyle(palette.secondary)
            }
            .padding(7)
            .background {
                if isSelected {
                    palette.shape.fill(palette.accent.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dimensionAccessibilityLabel(dimension, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func weightBar(_ value: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                bar(palette.border.opacity(0.3))
                bar(value > 0 ? palette.accent.opacity(0.85) : Color.clear)
                    .frame(width: max(0, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func bar(_ color: Color) -> some View {
        Group {
            if palette.retro {
                Rectangle().fill(color)
            } else {
                Capsule().fill(color)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(palette.font(8, weight: .bold))
            .foregroundStyle(palette.accent)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay { Capsule().strokeBorder(palette.accent.opacity(0.5), lineWidth: 0.8) }
    }

    private func dimensionAccessibilityLabel(_ dimension: RecommendationExplanationDimension, isSelected: Bool) -> String {
        let weight = String(format: "%.2f", dimension.longTerm)
        let evidence = english ? "\(dimension.evidenceCount) recent evidence items" : "最近 \(dimension.evidenceCount) 条证据"
        let selected = isSelected ? (english ? ", selected" : "，已选中") : ""
        let merged = dimension.manualFollowKeywords.isEmpty
            ? ""
            : (english ? ", includes follows \(dimension.manualFollowKeywords.joined(separator: ", "))" : "，含手动关注 \(dimension.manualFollowKeywords.joined(separator: "、"))")
        let reduced = dimension.isReduced ? (english ? ", reduced by an explicit rule" : "，被减少主题规则抵消") : ""
        let session = dimension.isSessionOnly ? (english ? ", session/recent only, not long-term" : "，仅会话/近期，非长期") : ""
        return english
            ? "\(dimension.label), weight \(weight), \(evidence)\(merged)\(reduced)\(session)\(selected)"
            : "\(dimension.label)，权重 \(weight)，\(evidence)\(merged)\(reduced)\(session)\(selected)"
    }
}

// MARK: - Connection graph

struct ExplanationConnectionCard: View {
    let connections: RecommendationExplanationConnections
    let palette: ExplanationPalette
    let language: AppLanguage

    private var english: Bool { language == .en }

    var body: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Tag links" : "标签关联",
            subtitle: english ? "Title hits only, not distance" : "仅标题命中，不是距离"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ExplanationConnectionGraph(connections: connections, palette: palette, language: language)
                ExplanationConnectionLegend(connections: connections, palette: palette, language: language)
                Text(connections.textAlternative(language))
                    .font(palette.font(9))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ExplanationConnectionGraph: View {
    let connections: RecommendationExplanationConnections
    let palette: ExplanationPalette
    let language: AppLanguage

    private var evidenceCount: Int { connections.evidence.count }
    private var candidateCount: Int { connections.candidates.count }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    drawEdges(context: context, size: canvasSize)
                }
                ForEach(Array(connections.evidence.enumerated()), id: \.element.id) { index, _ in
                    marker(text: "\(index + 1)", filled: false)
                        .position(x: 18, y: yPosition(index, count: evidenceCount, height: size.height))
                }
                tagNode
                    .position(x: size.width / 2, y: size.height / 2)
                ForEach(Array(connections.candidates.enumerated()), id: \.element.id) { index, _ in
                    marker(text: letter(index), filled: true)
                        .position(x: size.width - 18, y: yPosition(index, count: candidateCount, height: size.height))
                }
            }
        }
        .frame(height: 170)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connections.textAlternative(language))
    }

    private var tagNode: some View {
        Text(connections.label)
            .font(palette.font(11, weight: .bold))
            .foregroundStyle(palette.retro ? RetroEditorialTokens.raisedPaper : palette.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 150)
            .background {
                if palette.retro {
                    Rectangle().fill(RetroEditorialTokens.brick)
                } else {
                    Capsule().fill(palette.accent.opacity(0.16))
                }
            }
            .overlay {
                if palette.retro {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
                }
            }
    }

    private func marker(text: String, filled: Bool) -> some View {
        Text(text)
            .font(palette.mono(9, weight: .bold))
            .foregroundStyle(filled ? palette.accent : palette.ink)
            .frame(width: 22, height: 22)
            .background {
                Circle().fill(filled ? palette.accent.opacity(0.16) : palette.cardFill)
            }
            .overlay { Circle().strokeBorder(palette.border, lineWidth: 1) }
    }

    private func yPosition(_ index: Int, count: Int, height: CGFloat) -> CGFloat {
        guard count > 0 else { return height / 2 }
        let usable = max(24, height - 24)
        return 12 + usable * CGFloat(index + 1) / CGFloat(count + 1)
    }

    private func drawEdges(context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let tagHalfWidth = min(75, size.width * 0.20)
        var path = Path()
        for index in connections.evidence.indices {
            let point = CGPoint(x: 18, y: yPosition(index, count: evidenceCount, height: size.height))
            path.move(to: CGPoint(x: center.x - tagHalfWidth, y: center.y))
            path.addLine(to: point)
        }
        for index in connections.candidates.indices {
            let point = CGPoint(x: size.width - 18, y: yPosition(index, count: candidateCount, height: size.height))
            path.move(to: CGPoint(x: center.x + tagHalfWidth, y: center.y))
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(palette.accent.opacity(0.28)), lineWidth: 1)
    }

    private func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + min(index, 25)) else { return "?" }
        return String(Character(scalar))
    }
}

struct ExplanationConnectionLegend: View {
    let connections: RecommendationExplanationConnections
    let palette: ExplanationPalette
    let language: AppLanguage

    private var english: Bool { language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            groupTitle(english ? "Recent evidence" : "最近证据", count: connections.evidence.count)
            if connections.evidence.isEmpty {
                emptyText(english ? "No local titles match this tag." : "本地暂无命中该标签的标题。")
            } else {
                ForEach(Array(connections.evidence.enumerated()), id: \.element.id) { index, evidence in
                    legendRow(marker: "\(index + 1)", title: evidence.title, detail: "\(evidence.sourceName) · \(evidence.detail)")
                }
                if connections.listedEvidenceCount > connections.evidence.count {
                    emptyText(english
                        ? "\(connections.listedEvidenceCount) listed; the graph draws the first \(connections.evidence.count)."
                        : "已列出 \(connections.listedEvidenceCount) 条，图中仅画前 \(connections.evidence.count) 条。")
                }
            }
            groupTitle(english ? "Snapshot candidates" : "快照候选", count: connections.candidates.count)
            if connections.candidates.isEmpty {
                emptyText(english ? "No candidate in this snapshot matches." : "当前快照中没有命中该标签的候选。")
            } else {
                ForEach(Array(connections.candidates.enumerated()), id: \.element.id) { index, candidate in
                    legendRow(marker: letter(index), title: candidate.title, detail: candidate.sourceName)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func groupTitle(_ text: String, count: Int) -> some View {
        Text("\(text) · \(count)")
            .font(palette.font(9, weight: .bold))
            .foregroundStyle(palette.secondary)
            .padding(.top, 2)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(palette.font(9))
            .foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legendRow(marker: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(palette.mono(8, weight: .bold))
                .foregroundStyle(palette.accent)
                .frame(width: 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(palette.font(9))
                    .foregroundStyle(palette.ink)
                    .lineLimit(2)
                Text(detail)
                    .font(palette.font(8))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + min(index, 25)) else { return "?" }
        return String(Character(scalar))
    }
}
