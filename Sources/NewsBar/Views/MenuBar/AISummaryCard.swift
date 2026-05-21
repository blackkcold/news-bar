import SwiftUI

struct AISummaryCard: View {
    let state: AISummaryState
    @Binding var isExpanded: Bool
    var onRegenerate: (() -> Void)?
    var onConfigureKey: (() -> Void)?

    @State private var displayText = ""
    @State private var isRegenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerButton

            if isExpanded {
                contentArea
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear {
            switch state {
            case .done(let text), .truncated(let text):
                displayText = text
            default: break
            }
        }
        .onChange(of: state) { _, newState in
            switch newState {
            case .done(let text), .truncated(let text):
                Task { await animateText(text) }
            default:
                displayText = ""
            }
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                stateHeaderIcon
                Text("AI 总结")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                stateHeaderBadge
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stateHeaderIcon: some View {
        switch state {
        case .noKey:
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        case .fetching, .summarizing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        case .done, .truncated:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateHeaderBadge: some View {
        switch state {
        case .noKey:
            Text("未配置")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        case .fetching:
            Text("获取中")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .clipShape(Capsule())
        case .summarizing:
            Text("思考中")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.15))
                .clipShape(Capsule())
        case .error:
            Text("失败")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .clipShape(Capsule())
        case .truncated:
            Text("不完整")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .noKey:
                noKeyContent
            case .fetching:
                statusContent(message: "获取新闻数据...")
            case .summarizing:
                statusContent(message: "AI 思考中...")
            case .done, .truncated:
                summaryContent
            case .error(let msg):
                errorContent(msg)
            case .idle:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var noKeyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key 未配置")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text("需要配置 DeepSeek API Key 才能使用 AI 总结功能")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let onConfigureKey {
                Button {
                    onConfigureKey()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                        Text("配置 Key")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    private func statusContent(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayText)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(4)

            if case .truncated = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("摘要可能不完整")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Spacer()
                    if let onRegenerate {
                        regenerateButton(action: onRegenerate)
                    }
                }
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let onRegenerate {
                regenerateButton(action: onRegenerate)
            }
        }
    }

    private func regenerateButton(action: @escaping () -> Void) -> some View {
        Button {
            isRegenerating = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                isRegenerating = false
            }
        } label: {
            HStack(spacing: 4) {
                if isRegenerating {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                Text(isRegenerating ? "生成中..." : "重新生成")
                    .font(.system(size: 10))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRegenerating)
    }

    // MARK: - Animation

    @MainActor
    private func animateText(_ fullText: String) async {
        displayText = ""
        let chars: [Character] = Array(fullText)
        for i in 0...chars.count {
            if Task.isCancelled { return }
            displayText = String(chars.prefix(i))
            if i < chars.count {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }
}
