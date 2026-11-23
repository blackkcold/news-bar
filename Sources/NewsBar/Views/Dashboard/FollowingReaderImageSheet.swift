import AppKit
import SwiftUI

/// Which image the reader's lightbox is showing. Internal on purpose: the post
/// media grid presents it today, and the comment image strip will present the
/// same sheet once the payload is verified.
struct FollowingReaderImageSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
}

/// Full-size image viewer for the following reader.
///
/// The sheet keeps the previous image on screen while the next one decodes, so
/// stepping through a gallery never flashes an empty frame. `ImageCache`
/// answers a repeat request from memory, which is what makes the neighbour
/// prefetch worth doing.
struct FollowingReaderImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let urls: [URL]
    @State private var index: Int
    @State private var image: NSImage?
    @State private var imageURL: URL?
    @State private var imageFailed = false
    @State private var prefetchTask: Task<Void, Never>?

    init(urls: [URL], initialIndex: Int) {
        self.urls = urls
        _index = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
    }

    private var english: Bool { settings.appLanguage == .en }
    private var current: URL? { urls.indices.contains(index) ? urls[index] : nil }

    private func copy(_ zh: String, _ en: String) -> String { english ? en : zh }

    var body: some View {
        VStack(spacing: 12) {
            header
            stage
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        .background { keyboardShortcuts }
        .task(id: index) { await loadCurrent() }
        .onDisappear { prefetchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(index + 1) / \(urls.count)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if let current {
                Button { copyAddress(current) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(copy("复制图片地址", "Copy image address"))
                .accessibilityLabel(copy("复制图片地址", "Copy image address"))

                Button { NSWorkspace.shared.open(current) } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(copy("在浏览器中打开", "Open in browser"))
                .accessibilityLabel(copy("在浏览器中打开", "Open in browser"))
            }

            Button(copy("关闭", "Close")) { dismiss() }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
        }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    // Dim, never clear: the previous frame stays as context
                    // while the requested one decodes.
                    .opacity(imageURL == current ? 1 : 0.28)
            }

            if imageFailed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(copy("图片加载失败", "Image unavailable"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(copy("重试", "Retry")) {
                        Task { await loadCurrent(force: true) }
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                }
            } else if imageURL != current {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button { step(-1) } label: {
                Label(copy("上一张", "Previous"), systemImage: "chevron.left")
            }
            .disabled(index <= 0)

            Spacer()

            Button { step(1) } label: {
                Label(copy("下一张", "Next"), systemImage: "chevron.right")
            }
            .disabled(index >= urls.count - 1)
        }
    }

    /// Zero-sized buttons exist only to register the shortcuts. `onKeyPress`
    /// would need an explicit focus target; a sheet has none.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard urls.indices.contains(next) else { return }
        index = next
    }

    private func copyAddress(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @MainActor
    private func loadCurrent(force: Bool = false) async {
        guard let url = current else { return }
        if !force, imageURL == url, image != nil { return }

        if force {
            // `ImageCache` remembers a failure for five minutes. A retry that
            // does not clear it is a button that visibly does nothing.
            await ImageCache.shared.clearFailure(for: url, maxPixelSize: 2400)
        }

        imageFailed = false
        let loaded = await ImageCache.shared.image(for: url, maxPixelSize: 2400)
        guard !Task.isCancelled else { return }

        if let loaded {
            image = loaded
            imageURL = url
        } else {
            // Do not leave the previous picture at 28% under the error text.
            image = nil
            imageURL = nil
            imageFailed = true
        }

        prefetchNeighbours()
    }

    @MainActor
    private func prefetchNeighbours() {
        let targets = [index - 1, index + 1]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
        guard !targets.isEmpty else { return }
        // One prefetch at a time, cancelled when the sheet closes: stepping
        // quickly must not stack decode work that outlives the viewer.
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor in
            for url in targets {
                guard !Task.isCancelled else { return }
                _ = await ImageCache.shared.image(for: url, maxPixelSize: 2400)
            }
        }
    }
}
