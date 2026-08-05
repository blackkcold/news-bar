import SwiftUI

private struct CacheClearActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var cacheClearAction: (() -> Void)? {
        get { self[CacheClearActionKey.self] }
        set { self[CacheClearActionKey.self] = newValue }
    }
}

struct AboutTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.cacheClearAction) private var cacheClearAction

    @State private var showCacheClearConfirmation = false

    private let version = AppVersion.current
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(RetroEditorialTokens.brick)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NewsBar")
                                .editorialHeading(size: 17)
                            Text(L10n.string("about.versionText", version, build))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("macOS Menu Bar News Aggregator · AI Summaries · Weibo & Bilibili Trending · RSS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    Link(destination: URL(string: "https://github.com/blackkcold/news-bar")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text("github.com/blackkcold/news-bar")
                                .font(.system(size: 11))
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    dataSourceRow("about.weibo".localized, "s.weibo.com")
                    dataSourceRow("about.bilibili".localized, "bilibili.com")
                    dataSourceRow("about.rss".localized, "about.rssCustom".localized)
                }
            } header: {
                Text("about.dataSources".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DeepSeek · MiniMax · Opencode Go/Zen · Google AI Studio")
                        .font(.caption)
                    Text("about.aiModels".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("about.aiProviders".localized)
            }

            Section {
                Button("about.clearCache".localized) {
                    showCacheClearConfirmation = true
                }
                .foregroundStyle(.red)
            } header: {
                Text("about.dataManagement".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("about.privacy1".localized)
                    Text("about.privacy2".localized)
                    Text("about.privacy3".localized)
                    Text("about.privacy4".localized)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("about.privacyTitle".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("© 2024-2026 blackkcold & contributors")
                    Text("MIT License — Free & Open Source")
                    Text("Swift 5.9 · SwiftUI · macOS 15.0+")
                    Text("about.keywords".localized)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } header: {
                Text("about.licenseTitle".localized)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("about.clearCache.title".localized, isPresented: $showCacheClearConfirmation) {
            Button("about.clearCache".localized, role: .destructive) {
                cacheClearAction?()
            }
            Button("about.cancel".localized, role: .cancel) { }
        } message: {
            Text("about.clearCache.message".localized)
        }
    }

    private func dataSourceRow(_ name: String, _ source: String) -> some View {
        HStack {
            Text(name)
                .font(.caption)
            Spacer()
            Text(source)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
