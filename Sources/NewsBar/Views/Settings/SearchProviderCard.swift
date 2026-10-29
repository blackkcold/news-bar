import SwiftUI

/// One provider card in Settings → Research. Extracted from the settings
/// section so it can be rendered (and snapshot-tested) without the whole
/// settings surface.
struct SearchProviderCard: View {
    let provider: SearchProviderID
    let language: AppLanguage
    let status: SearchProviderStatus?
    let isEnabled: Bool
    let isConfigured: Bool
    let isSaving: Bool
    @Binding var keyInput: String
    let onToggle: (Bool) -> Void
    let onSave: () -> Void
    let onClear: () -> Void
    let onRetryAuth: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(authBadge)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("research.settings.providers.toggle".localized)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                if status?.state == .cooling, let until = status?.cooldownUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, until.timeIntervalSince(context.date))
                        Text(
                            L10n.string(
                                "research.providerStatus.coolingFor",
                                language: language,
                                Self.secondsLabel(remaining)
                            )
                        )
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text(stateLabel)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)

            if let quota = status?.quota, let usage = usageLabel(quota) {
                Text(usage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isEnabled {
                keyControls
            }

            if status?.state == .authRejected, let onRetryAuth {
                VStack(alignment: .leading, spacing: 4) {
                    Text("research.providerStatus.authHint".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("research.providerStatus.retryAuth".localized) {
                        onRetryAuth()
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField(
                    text: $keyInput,
                    prompt: Text(
                        L10n.string(
                            "research.settings.keyPlaceholder",
                            language: language,
                            provider.displayName
                        )
                    )
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)

                Button {
                    onSave()
                } label: {
                    Text("research.settings.keySave".localized)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .disabled(
                    isSaving
                        || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if isConfigured {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("research.settings.keyClear".localized)
                    .disabled(isSaving)
                }
            }

            HStack(spacing: 4) {
                if isConfigured {
                    Label("research.settings.keySaved".localized, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("research.settings.keyMissing".localized)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
        }
    }

    private var authBadge: String {
        switch provider.authMode {
        case .keyless: return "research.settings.authKeyless".localized
        case .optionalKey: return "research.settings.authOptional".localized
        case .requiredKey: return "research.settings.authRequired".localized
        }
    }

    private var stateLabel: String {
        L10n.string(
            "research.providerStatus.\((status?.state ?? .unattempted).rawValue)",
            language: language
        )
    }

    private var stateColor: Color {
        switch status?.state ?? .unattempted {
        case .succeeded: return .green
        case .authRejected, .forbidden: return .red
        case .cooling, .quotaExhausted, .transientFailure: return .orange
        case .disabled, .missingKey, .unattempted: return .secondary
        }
    }

    private func usageLabel(_ quota: SearchQuotaSnapshot) -> String? {
        if let daily = quota.dailyLimit {
            return L10n.string(
                "research.settings.usageDay",
                language: language,
                quota.usedToday,
                daily
            )
        }
        if let monthly = quota.monthlyLimit {
            return L10n.string(
                "research.settings.usageMonth",
                language: language,
                quota.usedThisMonth,
                monthly
            )
        }
        return nil
    }

    static func secondsLabel(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
