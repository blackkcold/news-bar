import SwiftUI

private struct EventMonitorTextDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

private struct EventMonitorAliasDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

private struct EventMonitorEntityDraft: Identifiable, Equatable {
    let id = UUID()
    var canonical: String
    var aliases: [EventMonitorAliasDraft]
}

private struct EventMonitorScopedDraft: Identifiable, Equatable {
    let id = UUID()
    var scope: NewsEventInterestScope
    var value: String
}

private struct EventMonitorInterestDraft {
    var keywords: [EventMonitorTextDraft] = []
    var entities: [EventMonitorEntityDraft] = []
    var legacyIncludes: [EventMonitorTextDraft] = []
    var legacyExcludes: [EventMonitorTextDraft] = []
    var scopedIncludes: [EventMonitorScopedDraft] = []
    var scopedExcludes: [EventMonitorScopedDraft] = []
    var hardBlocks: [EventMonitorTextDraft] = []
    var learningEnabled = false

    init(_ settings: NewsEventInterestSettings = NewsEventInterestSettings()) {
        keywords = settings.keywords.map(EventMonitorTextDraft.init(value:))
        entities = settings.aliases.keys.sorted().map { canonical in
            EventMonitorEntityDraft(
                canonical: canonical,
                aliases: (settings.aliases[canonical] ?? []).map(EventMonitorAliasDraft.init(value:))
            )
        }
        legacyIncludes = settings.includes.map(EventMonitorTextDraft.init(value:))
        legacyExcludes = settings.excludes.map(EventMonitorTextDraft.init(value:))
        scopedIncludes = settings.scopedIncludes.map {
            EventMonitorScopedDraft(scope: $0.scope, value: $0.value)
        }
        scopedExcludes = settings.scopedExcludes.map {
            EventMonitorScopedDraft(scope: $0.scope, value: $0.value)
        }
        hardBlocks = settings.hardBlocks.map(EventMonitorTextDraft.init(value:))
        learningEnabled = settings.learningEnabled
    }
}

struct EventMonitorInterestSettingsForm: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = EventMonitorInterestDraft()
    @State private var validationMessage: String?
    @State private var saveMessage: String?
    @State private var isSaving = false

    var body: some View {
        Group {
            Section {
                Toggle("event.preferences.learning".localized, isOn: $draft.learningEnabled)
                Text("event.preferences.learning.explanation".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ruleSummary)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("event.preferences.title".localized)
            } footer: {
                Text("event.preferences.learning.retention".localized)
            }

            Section {
                textRulesEditor(
                    title: "event.preferences.topic.keywords",
                    placeholder: "event.preferences.topic.placeholder",
                    rules: $draft.keywords
                )
                scopedRulesEditor(scope: .topic, include: true)
                scopedRulesEditor(scope: .topic, include: false)
            } header: {
                Text("event.preferences.topic".localized)
            } footer: {
                Text("event.preferences.topic.footer".localized)
            }

            Section {
                entityEditor
                scopedRulesEditor(scope: .entity, include: true)
                scopedRulesEditor(scope: .entity, include: false)
            } header: {
                Text("event.preferences.entity".localized)
            } footer: {
                Text("event.preferences.entity.footer".localized)
            }

            Section {
                scopedRulesEditor(scope: .region, include: true)
                scopedRulesEditor(scope: .region, include: false)
            } header: {
                Text("event.preferences.region".localized)
            } footer: {
                Text("event.preferences.region.footer".localized)
            }

            Section {
                scopedRulesEditor(scope: .source, include: true)
                scopedRulesEditor(scope: .source, include: false)
            } header: {
                Text("event.preferences.source".localized)
            } footer: {
                Text("event.preferences.source.footer".localized)
            }

            Section {
                textRulesEditor(
                    title: "event.preferences.legacyIncludes",
                    placeholder: "event.preferences.legacy.placeholder",
                    rules: $draft.legacyIncludes
                )
                textRulesEditor(
                    title: "event.preferences.legacyExcludes",
                    placeholder: "event.preferences.legacy.placeholder",
                    rules: $draft.legacyExcludes
                )
            } header: {
                Text("event.preferences.legacy.title".localized)
            } footer: {
                Text("event.preferences.legacy.footer".localized)
            }

            Section {
                textRulesEditor(
                    title: "event.preferences.hardBlocks",
                    placeholder: "event.preferences.hardBlocks.placeholder",
                    rules: $draft.hardBlocks
                )
                Label("event.preferences.hardBlocks.priority".localized, systemImage: "hand.raised.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("event.preferences.hardBlocks.title".localized)
            } footer: {
                Text("event.preferences.hardBlocks.footer".localized)
            }

            Section {
                Text("event.preferences.globalBlocks.explanation".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("event.preferences.globalBlocks.open".localized) {
                    NotificationCenter.default.post(name: .interestSettingsRequested, object: nil)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            } header: {
                Text("event.preferences.globalBlocks.title".localized)
            }

            Section {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saveMessage {
                    Label(saveMessage, systemImage: isSaving ? "hourglass" : "checkmark.circle.fill")
                        .foregroundStyle(isSaving ? Color.secondary : Color.green)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            Label("event.preferences.saving".localized, systemImage: "hourglass")
                        } else {
                            Label("event.preferences.save".localized, systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(EditorialActionButtonStyle(tone: .primary))
                    .disabled(isSaving)
                }
            }
        }
        .onAppear(perform: loadDraft)
    }

    private var ruleSummary: String {
        let hasExplicitRules = !draft.keywords.isEmpty || !draft.entities.isEmpty
            || !draft.scopedIncludes.isEmpty || !draft.scopedExcludes.isEmpty
            || !draft.legacyIncludes.isEmpty || !draft.legacyExcludes.isEmpty
            || !draft.hardBlocks.isEmpty
        return L10n.string(
            hasExplicitRules ? "event.preferences.rules.active" : "event.preferences.rules.open",
            language: settings.appLanguage
        )
    }

    private var entityEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("event.preferences.entity.aliases".localized)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    draft.entities.append(EventMonitorEntityDraft(canonical: "", aliases: []))
                    clearMessages()
                } label: {
                    Label("event.preferences.entity.add".localized, systemImage: "plus")
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            }

            if draft.entities.isEmpty {
                Text("event.preferences.entity.empty".localized)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            ForEach($draft.entities) { $entity in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("event.preferences.entity.canonical".localized, text: $entity.canonical)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("event.preferences.entity.canonical".localized)
                        Button(role: .destructive) {
                            draft.entities.removeAll { $0.id == entity.id }
                            clearMessages()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 30, minHeight: 30)
                        .accessibilityLabel("event.preferences.entity.remove".localized)
                    }

                    ForEach($entity.aliases) { $alias in
                        HStack(spacing: 7) {
                            TextField("event.preferences.entity.alias".localized, text: $alias.value)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                entity.aliases.removeAll { $0.id == alias.id }
                                clearMessages()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .frame(minWidth: 30, minHeight: 30)
                            .accessibilityLabel("event.preferences.entity.removeAlias".localized)
                        }
                    }

                    Button {
                        entity.aliases.append(EventMonitorAliasDraft(value: ""))
                        clearMessages()
                    } label: {
                        Label("event.preferences.entity.addAlias".localized, systemImage: "plus")
                    }
                    .buttonStyle(.link)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .newsCardSurface(cornerRadius: 10)
            }
        }
    }

    private func textRulesEditor(
        title: String,
        placeholder: String,
        rules: Binding<[EventMonitorTextDraft]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.string(title, language: settings.appLanguage))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    rules.wrappedValue.append(EventMonitorTextDraft(value: ""))
                    clearMessages()
                } label: {
                    Label("event.preferences.rule.add".localized, systemImage: "plus")
                }
                .buttonStyle(.link)
            }
            ForEach(rules) { $rule in
                HStack(spacing: 7) {
                    TextField(L10n.string(placeholder, language: settings.appLanguage), text: $rule.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        rules.wrappedValue.removeAll { $0.id == rule.id }
                        clearMessages()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 30, minHeight: 30)
                    .accessibilityLabel(L10n.string("event.preferences.rule.remove", language: settings.appLanguage))
                }
            }
            if rules.wrappedValue.isEmpty {
                Text("event.preferences.rule.empty".localized)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func scopedRulesEditor(scope: NewsEventInterestScope, include: Bool) -> some View {
        let rules = Binding<[EventMonitorScopedDraft]>(
            get: { include ? draft.scopedIncludes.filter { $0.scope == scope } : draft.scopedExcludes.filter { $0.scope == scope } },
            set: { updated in
                if include {
                    draft.scopedIncludes.removeAll { $0.scope == scope }
                    draft.scopedIncludes.append(contentsOf: updated)
                } else {
                    draft.scopedExcludes.removeAll { $0.scope == scope }
                    draft.scopedExcludes.append(contentsOf: updated)
                }
            }
        )

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.string(include ? "event.preferences.include" : "event.preferences.exclude", language: settings.appLanguage))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    rules.wrappedValue.append(EventMonitorScopedDraft(scope: scope, value: ""))
                    clearMessages()
                } label: {
                    Label("event.preferences.rule.add".localized, systemImage: "plus")
                }
                .buttonStyle(.link)
            }
            ForEach(rules) { $rule in
                HStack(spacing: 7) {
                    TextField("event.preferences.rule.value".localized, text: $rule.value)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.string("event.preferences.scope.\(scope.rawValue)", language: settings.appLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button(role: .destructive) {
                        rules.wrappedValue.removeAll { $0.id == rule.id }
                        clearMessages()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 30, minHeight: 30)
                    .accessibilityLabel("event.preferences.rule.remove".localized)
                }
            }
            if rules.wrappedValue.isEmpty {
                Text("event.preferences.rule.empty".localized)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func loadDraft() {
        draft = EventMonitorInterestDraft(settings.newsEventInterestSettings)
        validationMessage = nil
        saveMessage = nil
    }

    private func clearMessages() {
        validationMessage = nil
        saveMessage = nil
    }

    private func save() async {
        clearMessages()
        guard let snapshot = makeSnapshot() else { return }
        isSaving = true
        settings.newsEventInterestSettings = snapshot

        let controller = NewsEventController.shared(settings: settings)
        await controller.reload(now: Date())
        isSaving = false
        if case .failed(let message, _) = controller.state {
            saveMessage = L10n.string(
                "event.preferences.savedRecomputeFailed",
                language: settings.appLanguage,
                message
            )
        } else {
            saveMessage = "event.preferences.saved".localized
        }
    }

    private func makeSnapshot() -> NewsEventInterestSettings? {
        func normalized(_ rules: [EventMonitorTextDraft]) -> [String] {
            var seen: Set<String> = []
            return rules.compactMap { rule in
                let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let identity = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard seen.insert(identity).inserted else { return nil }
                return value
            }
        }

        let keywords = normalized(draft.keywords)
        let legacyIncludes = normalized(draft.legacyIncludes)
        let legacyExcludes = normalized(draft.legacyExcludes)
        let hardBlocks = normalized(draft.hardBlocks)

        var aliases: [String: [String]] = [:]
        var canonicalKeys: Set<String> = []
        for entity in draft.entities {
            let canonical = entity.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if canonical.isEmpty {
                validationMessage = "event.preferences.validation.canonicalRequired".localized
                return nil
            }
            let canonicalKey = canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard canonicalKeys.insert(canonicalKey).inserted else {
                validationMessage = "event.preferences.validation.canonicalDuplicate".localized
                return nil
            }
            var seenAliases: Set<String> = []
            var values: [String] = []
            for alias in entity.aliases {
                let value = alias.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    validationMessage = "event.preferences.validation.aliasRequired".localized
                    return nil
                }
                let identity = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seenAliases.insert(identity).inserted { values.append(value) }
            }
            aliases[canonical] = values
        }

        func normalizedScoped(_ rules: [EventMonitorScopedDraft]) -> [NewsEventInterestRule]? {
            var seen: Set<String> = []
            var values: [NewsEventInterestRule] = []
            for rule in rules {
                let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    validationMessage = "event.preferences.validation.ruleRequired".localized
                    return nil
                }
                let identity = "\(rule.scope.rawValue):\(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
                if seen.insert(identity).inserted {
                    values.append(NewsEventInterestRule(scope: rule.scope, value: value))
                }
            }
            return values
        }

        guard let scopedIncludes = normalizedScoped(draft.scopedIncludes),
              let scopedExcludes = normalizedScoped(draft.scopedExcludes) else { return nil }

        return NewsEventInterestSettings(
            keywords: keywords,
            aliases: aliases,
            includes: legacyIncludes,
            excludes: legacyExcludes,
            hardBlocks: hardBlocks,
            learningEnabled: draft.learningEnabled,
            scopedIncludes: scopedIncludes,
            scopedExcludes: scopedExcludes
        )
    }
}
