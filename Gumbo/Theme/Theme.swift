import GumboCore
import SwiftUI

/// Stable neutral canvas keeps artwork and blue actions distinct while the library scrolls.
struct TintedBackground: View {
    var tint: Color

    var body: some View {
        Palette.paper.ignoresSafeArea()
    }
}

/// The tinted paper behind a screen, with the navigation bar pinned to the same light or dark look.
/// Left adaptive, the bar's glass flips its title to white whenever a dark cover scrolls under it,
/// which reads as white text on a pale page.
private struct GumboBackground: ViewModifier {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .background(TintedBackground(tint: tint))
            .toolbarColorScheme(colorScheme, for: .navigationBar)
        #elseif os(macOS)
        content.background(Palette.paper)
        #else
        content
            .background(TintedBackground(tint: tint))
        #endif
    }
}

extension View {
    /// Applies the tinted paper background behind any screen.
    func gumboBackground(_ tint: Color) -> some View {
        modifier(GumboBackground(tint: tint))
    }
}
