import SwiftUI

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            TabView(selection: $selectedTab) {
                GeneralTab()
                    .tabItem {
                        Label("通用", systemImage: "gearshape")
                    }
                    .tag(0)

                RSSTab()
                    .tabItem {
                        Label("RSS", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(1)

                AITab()
                    .tabItem {
                        Label("AI", systemImage: "sparkles")
                    }
                    .tag(2)

                NotificationTab()
                    .tabItem {
                        Label("通知", systemImage: "bell.fill")
                    }
                    .tag(4)

                AboutTab()
                    .tabItem {
                        Label("关于", systemImage: "info.circle")
                    }
                    .tag(3)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToAITab)) { _ in
                selectedTab = 2
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("退出 NewsBar")
                        .font(.system(size: 12))
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .destructive, compact: true))
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 460, minHeight: 380)
        .padding(.top, 8)
        .adaptiveColorScheme()
        .appThemeSurface()
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            if selectedTab == 1 {
                EditorialSourceBadge(mark: .rss, fallbackTint: .blue, size: 32, rotation: -1)
            } else {
                EditorialSymbolBadge(
                    symbol: selectedTabSymbol,
                    fallbackTint: .accentColor,
                    size: 32,
                    rotation: -1
                )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(selectedTabTitle)
                    .editorialHeading(size: 16)
                    .lineLimit(1)
                Text(selectedTabSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            EditorialTag(text: "设置", fallbackTint: .secondary, filled: settings.appTheme == .retroEditorial)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .editorialMasthead()
        .accessibilityElement(children: .combine)
    }

    private var selectedTabTitle: String {
        switch selectedTab {
        case 1: return "RSS 新闻源"
        case 2: return "AI 编辑部"
        case 3: return "关于 NewsBar"
        case 4: return "通知中心"
        default: return "通用设置"
        }
    }

    private var selectedTabSubtitle: String {
        switch selectedTab {
        case 1: return "订阅、排序与展示方式"
        case 2: return "提供商、模型与用量控制"
        case 3: return "版本、数据来源与隐私"
        case 4: return "权限、频率与每日摘要"
        default: return "刷新、外观与诊断"
        }
    }

    private var selectedTabSymbol: String {
        switch selectedTab {
        case 2: return "sparkles"
        case 3: return "info.circle"
        case 4: return "bell.fill"
        default: return "gearshape"
        }
    }
}
