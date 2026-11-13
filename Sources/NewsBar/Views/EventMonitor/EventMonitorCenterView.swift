import SwiftUI

struct EventMonitorCenterView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: EventMonitorCenterModel
    let onOpenReminderSettings: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            EventMonitorSidebar(model: model, onOpenReminderSettings: onOpenReminderSettings)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } content: {
            eventList
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 390)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 660)
        .adaptiveColorScheme()
        .appThemeSurface()
        .task { await model.load() }
        .onChange(of: model.filter) { _, _ in model.reconcileSelectionAfterFilterChange() }
        .onChange(of: model.searchText) { _, _ in model.reconcileSelectionAfterFilterChange() }
        .onMoveCommand(perform: model.moveSelection)
        .background { keyboardShortcuts }
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            searchBar
            if let message = model.routeMessage, !message.isEmpty {
                messageBanner(message)
            }
            if hasCapacityNotice {
                messageBanner(
                    model.controller.budgetSnapshot.capacityReason ?? "event.capacity.limited".localized,
                    warning: true
                )
            }
            listContents
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("event.search.placeholder".localized, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
                .accessibilityLabel("event.search.label".localized)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel("event.search.clear".localized)
            }
            Button {
                Task { await model.reload() }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 30, minHeight: 30)
            .disabled(model.isRefreshing || model.isChecking)
            .help("event.refresh.local.help".localized)
            .accessibilityLabel("event.refresh.local".localized)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .editorialClipShape(cornerRadius: 9)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var listContents: some View {
        let events = model.visibleEvents
        switch model.controller.state {
        case .idle:
            loadingOrEmptyState
        case .loading:
            if model.controller.events.isEmpty {
                loadingOrEmptyState
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("event.refresh.cacheVisible".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    loadedList(events)
                }
            }
        case .loaded:
            loadedList(events)
        case .failed(let message, false):
            failureState(message)
        case .failed(let message, true):
            VStack(spacing: 0) {
                messageBanner(L10n.string("event.refresh.failedCached", language: settings.appLanguage, message), warning: true)
                loadedList(events)
            }
        }
    }

    @ViewBuilder
    private var loadingOrEmptyState: some View {
        if model.controller.events.isEmpty, case .loaded = model.controller.state {
            emptyCandidateState
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("event.loading".localized)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedList(_ events: [NewsEvent]) -> some View {
        Group {
            if events.isEmpty {
                if model.controller.events.isEmpty {
                    emptyCandidateState
                } else {
                    noResultsState
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(events) { event in
                            Button {
                                model.select(event.id)
                            } label: {
                                EventMonitorListRow(event: event, isSelected: event.id == model.selectedEventID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(event.id == model.selectedEventID ? .isSelected : [])
                        }
                    }
                    .padding(9)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCandidateState: some View {
        ContentUnavailableView {
            Label("event.empty.title".localized, systemImage: "newspaper")
        } description: {
            Text("event.empty.description".localized)
        } actions: {
            Button("event.refresh.local".localized) {
                Task { await model.reload() }
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("event.search.empty".localized, systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("event.search.empty.description".localized)
        } actions: {
            Button("event.search.clearFilters".localized) {
                model.filter = .all
                model.searchText = ""
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("event.refresh.failed.title".localized, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("event.refresh.retry".localized) {
                Task { await model.reload() }
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let event = model.event(id: model.selectedEventID) {
            EventMonitorDetailView(
                model: model,
                event: event,
                onOpenReminderSettings: onOpenReminderSettings
            )
        } else if let message = model.routeMessage {
            ContentUnavailableView {
                Label("event.selection.unavailable".localized, systemImage: "questionmark.folder")
            } description: {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("event.detail.select".localized, systemImage: "sidebar.right")
            } description: {
                Text("event.detail.select.description".localized)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func messageBanner(_ message: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(warning ? Color.orange.opacity(0.09) : Color.primary.opacity(0.045))
        .accessibilityElement(children: .combine)
    }

    private var keyboardShortcuts: some View {
        Button("event.search.focus".localized) { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var hasCapacityNotice: Bool {
        model.controller.trackingState == .capacityLimited
            || model.controller.budgetSnapshot.capacityReason != nil
    }
}

private struct EventMonitorSidebar: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: EventMonitorCenterModel
    let onOpenReminderSettings: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("event.window.title".localized)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("event.window.subtitle".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 17)
            .padding(.bottom, 13)

            Divider()

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(NewsEventListFilter.allCases) { filter in
                        filterButton(filter)
                    }
                }
                .padding(8)
            }

            Spacer(minLength: 8)
            Divider()
            budgetSummary

            Button(action: onOpenReminderSettings) {
                Label("event.settings.open".localized, systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background {
            if isRetro { RetroEditorialTokens.raisedPaper }
        }
    }

    private func filterButton(_ filter: NewsEventListFilter) -> some View {
        let selected = model.filter == filter
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(L10n.string(filter.titleKey, language: settings.appLanguage))
                    .font(.body.weight(selected ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 3)
                Text("\(model.count(for: filter))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            .editorialClipShape(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(
            "event.filter.accessibility",
            language: settings.appLanguage,
            L10n.string(filter.titleKey, language: settings.appLanguage),
            model.count(for: filter)
        ))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var budgetSummary: some View {
        let snapshot = model.controller.budgetSnapshot
        return VStack(alignment: .leading, spacing: 5) {
            Label("event.budget.title".localized, systemImage: "gauge.with.dots.needle.67percent")
                .font(.subheadline.weight(.semibold))
            Text(L10n.string("event.budget.\(snapshot.availability.rawValue)", language: settings.appLanguage))
                .font(.callout)
            if let used = snapshot.checksUsed, let limit = snapshot.checksLimit {
                Text(L10n.string("event.budget.checkCount", language: settings.appLanguage, used, limit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let resetsAt = snapshot.resetsAt {
                Text(L10n.string(
                    "event.budget.resetAt",
                    language: settings.appLanguage,
                    resetsAt.formatted(date: .abbreviated, time: .shortened)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let reason = snapshot.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("event.budget.readOnly".localized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface()
        .padding(9)
    }
}
