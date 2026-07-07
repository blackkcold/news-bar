import SwiftUI

struct RSSTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var newURL = ""
    @State private var newName = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var addWarning: String?
    @State private var isTesting = false
    @State private var showRecommendations = false
    @State private var showMaxAlert = false

    private let maxSelected = 3

    var body: some View {
        Form {
            Section {
                if settings.rssSources.isEmpty {
                    emptySourcesView
                } else {
                    ForEach(settings.rssSources) { rss in
                        rssSourceRow(rss)
                    }
                }
            } header: {
                HStack {
                    Text("我的 RSS 源 (\(settings.selectedRSSSourceIDs.count)/\(maxSelected))")
                    Spacer()
                    Button {
                        withAnimation { showRecommendations.toggle() }
                    } label: {
                        Text(showRecommendations ? "隐藏推荐" : "推荐列表")
                            .font(.caption)
                    }
                }
            }

            if showRecommendations {
                Section {
                    ForEach(RSSRecommendations.all) { rec in
                        recommendationRow(rec)
                    }
                } header: {
                    Text("推荐 RSS 源")
                }
            }

            Section {
                addRSSForm
            } header: {
                Text("添加 RSS 源")
            }
        }
        .formStyle(.grouped)
        .alert("提示", isPresented: $showMaxAlert) {
            Button("知道了") { }
        } message: {
            Text("最多只能选择3个RSS源")
        }
    }

    private var emptySourcesView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("暂无 RSS 源，点击下方推荐列表或手动添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private func rssSourceRow(_ rss: RSSSourceConfig) -> some View {
        let isSelected = settings.selectedRSSSourceIDs.contains(rss.id)
        let isDisabled = !isSelected && settings.selectedRSSSourceIDs.count >= maxSelected

        return HStack(spacing: 8) {
            Button {
                toggleSelection(rss.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(rss.name)
                    .font(.system(size: 13, weight: .medium))
                Text(rss.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { rss.displayMode },
                set: { newMode in
                    if let idx = settings.rssSources.firstIndex(where: { $0.id == rss.id }) {
                        settings.rssSources[idx].displayMode = newMode
                    }
                }
            )) {
                Text("固定").tag(RSSSourceConfig.DisplayMode.single)
                Text("滚动").tag(RSSSourceConfig.DisplayMode.scroll)
            }
            .labelsHidden()
            .frame(width: 60)

            Button {
                settings.rssSources.removeAll { $0.id == rss.id }
                settings.selectedRSSSourceIDs.remove(rss.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .opacity(isDisabled ? 0.4 : 1.0)
        .padding(.vertical, 2)
    }

    private func toggleSelection(_ id: String) {
        if settings.selectedRSSSourceIDs.contains(id) {
            settings.selectedRSSSourceIDs.remove(id)
        } else if settings.selectedRSSSourceIDs.count < maxSelected {
            settings.selectedRSSSourceIDs.insert(id)
        } else {
            showMaxAlert = true
        }
    }

    @ViewBuilder
    private func recommendationRow(_ rec: RSSRecommendation) -> some View {
        let isAdded = settings.rssSources.contains { $0.url == rec.url }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(size: 13, weight: .medium))
                Text(rec.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(rec.category.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())

            if isAdded {
                Text("已添加")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("添加") {
                    addRecommended(rec)
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func addRecommended(_ rec: RSSRecommendation) {
        let source = RSSSourceConfig(name: rec.name, url: rec.url, displayMode: .single)
        settings.rssSources.append(source)
        if settings.selectedRSSSourceIDs.count < maxSelected {
            settings.selectedRSSSourceIDs.insert(source.id)
        }
        NotificationCenter.default.post(
            name: .rssSourceAdded,
            object: nil,
            userInfo: ["url": rec.url, "name": rec.name]
        )
    }

    private var addRSSForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("源名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("RSS URL", text: $newURL)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = addError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let warning = addWarning {
                Text("⚠️ \(warning)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(action: addRSSSource) {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text("添加并验证")
                    }
                }
                .disabled(newName.isEmpty || newURL.isEmpty || isTesting)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addRSSSource() {
        let sanitizedURL = SecurityPolicies.sanitizeUserInput(newURL)
        let sanitizedName = SecurityPolicies.sanitizeUserInput(newName)

        guard !sanitizedURL.isEmpty else {
            addError = "请输入 RSS URL"
            return
        }

        var normalizedURL = sanitizedURL
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }

        switch SecurityPolicies.validateRSSURL(normalizedURL) {
        case .valid:
            break
        case .blocked(let reason):
            addError = reason
            return
        case .warning(let reason):
            addWarning = reason
            addError = nil
            // warning is non-blocking, user can still add
        }

        isTesting = true

        Task {
            do {
                let isValid = try await RSSService.validate(normalizedURL)
                if isValid {
                    let source = RSSSourceConfig(
                        name: sanitizedName, url: normalizedURL, displayMode: .single
                    )
                    settings.rssSources.append(source)
                    if settings.selectedRSSSourceIDs.count < maxSelected {
                        settings.selectedRSSSourceIDs.insert(source.id)
                    }
                    newURL = ""
                    newName = ""
                    addError = nil
                    addWarning = nil
                    NotificationCenter.default.post(
                        name: .rssSourceAdded,
                        object: nil,
                        userInfo: ["url": normalizedURL, "name": sanitizedName]
                    )
                } else {
                    addError = "该地址不是有效的 RSS/Atom Feed"
                }
            } catch {
                addError = "无法连接到该地址"
            }
            isTesting = false
        }
    }
}
