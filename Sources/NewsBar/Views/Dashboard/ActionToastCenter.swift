import Observation
import SwiftUI

/// One transient confirmation with an optional undo. Shared by the dashboard
/// feed and rendered as a floating capsule at the bottom of the browse pane, so
/// an action that hides a card still leaves a visible way back.
@MainActor
@Observable
final class ActionToastCenter {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: (@MainActor () -> Void)?
    }

    static let shared = ActionToastCenter()

    private(set) var toast: Toast?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        let next = Toast(message: message, undo: undo)
        toast = next
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.toast?.id == next.id else { return }
            self?.toast = nil
        }
    }

    func undo() {
        let action = toast?.undo
        toast = nil
        dismissTask?.cancel()
        action?()
    }

    func dismiss() {
        toast = nil
        dismissTask?.cancel()
    }
}

struct ActionToastView: View {
    @Environment(AppSettings.self) private var settings
    let toast: ActionToastCenter.Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            if toast.undo != nil {
                Button(L10n.string("common.undo", language: settings.appLanguage)) {
                    ActionToastCenter.shared.undo()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.18)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
