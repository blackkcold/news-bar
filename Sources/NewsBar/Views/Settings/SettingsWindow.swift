import SwiftUI

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 460, minHeight: 380)
        .padding(.top, 8)
        .adaptiveColorScheme()
    }
}
