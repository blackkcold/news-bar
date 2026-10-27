import SwiftUI

struct ResearchCenterView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchCenterModel

    var body: some View {
        NavigationSplitView {
            ResearchSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } content: {
            ResearchListPane(model: model)
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 380)
        } detail: {
            ResearchDetailPane(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 660)
        .adaptiveColorScheme()
        .appThemeSurface()
        .task { await model.load() }
    }
}

private struct ResearchSidebar: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchCenterModel

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("research.center.title".localized)
                    .font(.system(size: 18, weight: isRetro ? .black : .bold, design: isRetro ? .serif : .default))
                Text("research.center.subtitle".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ResearchCenterFilter.allCases) { filter in
                        filterButton(filter)
                    }
                }
                .padding(8)
            }

            Spacer(minLength: 0)
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text(L10n.string("research.storage", storageText))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .background(isRetro ? AnyShapeStyle(RetroEditorialTokens.raisedPaper) : AnyShapeStyle(.thinMaterial))
    }

    private func filterButton(_ filter: ResearchCenterFilter) -> some View {
        let selected = model.filter == filter
        let count = model.entries.filter { filter.matches($0) }.count
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(filter.titleKey.localized)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            .editorialClipShape(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file)
    }
}

private struct ResearchListPane: View {
    @Bindable var model: ResearchCenterModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("research.search.placeholder".localized, text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("research.search.clear".localized)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .editorialClipShape(cornerRadius: 8)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Picker("", selection: $model.sort) {
                    ForEach(ResearchSort.allCases) { sort in
                        Text(sort.titleKey.localized).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Spacer(minLength: 0)

                Toggle("research.filter.unreadOnly".localized, isOn: $model.onlyUnread)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 3) {
                    ForEach(model.visibleEntries) { entry in
                        Button {
                            Task { await model.select(entry.id) }
                        } label: {
                            ResearchListRow(
                                entry: entry,
                                isSelected: entry.id == model.selectedID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            if model.visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(model.entries.isEmpty ? "research.empty.title".localized : "research.empty.list".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        .background(.background)
    }
}

private struct ResearchDetailPane: View {
    @Bindable var model: ResearchCenterModel

    var body: some View {
        if let record = model.selectedRecord {
            ResearchDetailView(model: model, record: record)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(model.entries.isEmpty ? "research.empty.title".localized : "research.empty.detail".localized)
                    .font(.system(size: 13, weight: .medium))
                if model.entries.isEmpty {
                    Text("research.empty.body".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        }
    }
}
