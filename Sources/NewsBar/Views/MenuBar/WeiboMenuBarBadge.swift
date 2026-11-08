import AppKit

/// Composes the menu-bar icon and the unread badge. When there is nothing to
/// show, it returns the untouched template symbol so the system keeps its
/// normal menu-bar tint; only a real unread count pays for a custom drawing.
enum WeiboMenuBarBadge {
    static func image(unread: Int) -> NSImage? {
        guard unread > 0 else {
            let icon = NSImage(
                systemSymbolName: "newspaper.fill",
                accessibilityDescription: "NewsBar"
            )
            icon?.isTemplate = true
            return icon
        }

        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let symbol = NSImage(
                systemSymbolName: "newspaper.fill",
                accessibilityDescription: nil
            ) else {
                return false
            }
            let iconRect = NSRect(x: 0, y: 0, width: 18, height: 18)
            symbol.draw(in: iconRect)
            // Recolor the symbol's opaque pixels to the current menu-bar label
            // color so the custom (non-template) badge image still adapts to
            // light and dark menu bars.
            NSColor.labelColor.set()
            iconRect.fill(using: .sourceAtop)

            let diameter: CGFloat = 10
            let badgeRect = NSRect(
                x: size.width - diameter,
                y: size.height - diameter,
                width: diameter,
                height: diameter
            )
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let text = unread > 99 ? "99+" : "\(unread)"
            let fontSize: CGFloat
            switch text.count {
            case 1: fontSize = 7.5
            case 2: fontSize = 6.5
            default: fontSize = 5.5
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: badgeRect.midX - textSize.width / 2,
                    y: badgeRect.midY - textSize.height / 2 + 0.4
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        return image
    }
}
