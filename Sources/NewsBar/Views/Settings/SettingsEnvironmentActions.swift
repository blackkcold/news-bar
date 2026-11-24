import SwiftUI
import UserNotifications

/// Actions the settings window cannot own: they need the orchestrator or the
/// notification centre. Declared once here, injected at the settings window
/// root in `AppDelegate`, and read by the sections that need them.
private struct CacheClearActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct ResearchHistoryClearActionKey: EnvironmentKey {
    static let defaultValue: (() async -> ResearchClearResult)? = nil
}

private struct SearchProviderStatusActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AppSettings) async -> [SearchProviderStatus])? = nil
}

private struct SearchAuthRetryActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (SearchProviderID) async -> Void)? = nil
}

private struct RSSHealthActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AppSettings) -> [RSSSourceHealth])? = nil
}

private struct SettingsNotificationAuthorizationActionKey: EnvironmentKey {
    static let defaultValue: @MainActor () async -> UNAuthorizationStatus = {
        await NotificationService.authorizationStatus()
    }
}

extension EnvironmentValues {
    var cacheClearAction: (() -> Void)? {
        get { self[CacheClearActionKey.self] }
        set { self[CacheClearActionKey.self] = newValue }
    }

    /// Settings and About both clear research history through the one
    /// orchestrator-owned flow.
    var researchHistoryClearAction: (() async -> ResearchClearResult)? {
        get { self[ResearchHistoryClearActionKey.self] }
        set { self[ResearchHistoryClearActionKey.self] = newValue }
    }

    var searchProviderStatusAction: (@MainActor (AppSettings) async -> [SearchProviderStatus])? {
        get { self[SearchProviderStatusActionKey.self] }
        set { self[SearchProviderStatusActionKey.self] = newValue }
    }

    var searchAuthRetryAction: (@MainActor (SearchProviderID) async -> Void)? {
        get { self[SearchAuthRetryActionKey.self] }
        set { self[SearchAuthRetryActionKey.self] = newValue }
    }

    var rssHealthAction: (@MainActor (AppSettings) -> [RSSSourceHealth])? {
        get { self[RSSHealthActionKey.self] }
        set { self[RSSHealthActionKey.self] = newValue }
    }

    var settingsNotificationAuthorizationStatusAction: @MainActor () async -> UNAuthorizationStatus {
        get { self[SettingsNotificationAuthorizationActionKey.self] }
        set { self[SettingsNotificationAuthorizationActionKey.self] = newValue }
    }
}
