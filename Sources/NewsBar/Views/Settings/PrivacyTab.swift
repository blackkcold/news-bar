import SwiftUI

/// 隐私与数据页签：本地兴趣画像、阅读器 Cookie/历史、研究数据与缓存。
/// 三块都只关乎「这台机器上留下了什么」，原先分散在通用、浏览器与关于三处。
struct PrivacyTab: View {
    var body: some View {
        Form {
            InterestPrivacySection()
            BrowserDataTab()
            ResearchDataSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
