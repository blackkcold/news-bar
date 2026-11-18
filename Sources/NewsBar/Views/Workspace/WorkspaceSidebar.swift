import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let onNewTopic: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("research.workspace.title".localized)
                    .font(.system(size: 17, weight: isRetro ? .black : .semibold,
                                  design: isRetro ? .serif : .default))
                Text("research.workspace.subtitle".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(WorkspaceFilter.sidebarOrder) { filter in
                        filterButton(filter)
                    }
                }
                .padding(8)
            }

            Spacer(minLength: 0)
            Divider()

            Button(action: onNewTopic) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("workspace.action.newTopic".localized)
                        .font(.system(size: 11, weight: isRetro ? .black : .medium))
                    Spacer(minLength: 0)
                    Text("⌘N")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityLabel("workspace.action.newTopic".localized)

            footer
        }
        .background {
            if isRetro {
                RetroEditorialTokens.raisedPaper
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("research.workspace.title".localized)
    }

    private func filterButton(_ filter: WorkspaceFilter) -> some View {
        let selected = model.filter == filter
        let count = model.count(for: filter)
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(filter.titleKey.localized)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? accent : .secondary)
            }
            .foregroundStyle(selected ? accent : .primary)
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(selected ? accent.opacity(0.12) : Color.clear)
            .editorialClipShape(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.titleKey.localized)，\(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: model.isReadOnly ? "lock.doc" : "internaldrive")
                    .font(.system(size: 9))
                Text(L10n.string(
                    "workspace.storage.summary",
                    language: settings.appLanguage,
                    model.subjects.count
                ))
                    .font(.system(size: 9.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            if model.isReadOnly {
                Text("workspace.readOnly.short".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if model.bootstrap?.rebuilt == true {
                Text("workspace.storage.rebuilt".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("workspace.follow.help".localized)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
