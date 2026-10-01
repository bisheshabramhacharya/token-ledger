import AppKit

/// Menu bar icon. A template image, so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "TokenLedger")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
