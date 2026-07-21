import SwiftUI
import AppKit

/// Loads the app's own icon artwork from the bundle (assembled by make-app.sh into
/// Contents/Resources). Falls back to the vector `DriveGlyph` if a file is missing,
/// so the UI never renders blank.
enum AppArtwork {
    /// The full-color icon, trimmed to the rounded tile. For the start screen.
    static let color: NSImage? = load("AppIconColor")

    /// The official yellow "Buy me a coffee" button image, for the Support tab.
    static let buyMeACoffeeButton: NSImage? = load("BuyMeACoffeeButton")

    /// A monochrome template keyed from the icon's white artwork. For the menu bar;
    /// `isTemplate` lets macOS recolor it for the light/dark menu bar. The point
    /// size is fixed so the status item renders it at a normal menu-bar scale
    /// instead of stretching it to the full bar height.
    static let template: NSImage? = {
        guard let image = load("MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}

/// The color app icon for the start screen, with a vector fallback.
struct AppIconColorView: View {
    var size: CGFloat

    var body: some View {
        if let image = AppArtwork.color {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            DriveGlyph(lineWidth: 5)
                .frame(width: size * 0.9, height: size * 0.9)
                .foregroundStyle(.tint)
        }
    }
}

/// The monochrome template icon for the menu bar, with a vector fallback.
struct MenuBarIconView: View {
    var size: CGFloat = 18

    var body: some View {
        if let image = AppArtwork.template {
            // Use the image's own point size (set in AppArtwork) so the status
            // item scales it like a normal menu-bar icon.
            Image(nsImage: image)
        } else {
            DriveGlyph(lineWidth: 8)
                .frame(width: size, height: size)
        }
    }
}
