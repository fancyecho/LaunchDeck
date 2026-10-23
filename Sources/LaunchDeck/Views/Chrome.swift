import AppKit
import Observation
import SwiftUI

/// The bits of launcher state the SwiftUI search bar renders.
@Observable
final class ChromeState {
    var query = ""
    /// Text an input method is still composing (pinyin before a candidate is picked).
    var markedText = ""
    var isShown = false
    /// True while a folder is open; the search bar steps aside.
    var hidesChrome = false
    /// Clicked or typed into: shows the caret.
    var isFocused = false
    var isHovered = false

    /// Idle, the bar rests as a small glass lens; it opens up when pointed at,
    /// clicked or typed into.
    var isExpanded: Bool { isFocused || isHovered || !query.isEmpty || !markedText.isEmpty }
    var hasText: Bool { !query.isEmpty || !markedText.isEmpty }
}

/// Hosts the search bar without taking clicks; the canvas handles all input.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SearchBarContainer: View {
    let state: ChromeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = state.isShown && !state.hidesChrome
        SearchBar(query: state.query, markedText: state.markedText,
                  isFocused: visible && state.isFocused, isExpanded: state.isExpanded)
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : -12)
            .animation(visible ? .spring(response: 0.5, dampingFraction: 0.82).delay(0.05) : .easeIn(duration: 0.16),
                       value: visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Liquid Glass search capsule. Text comes from the canvas (key monitor plus the
/// input method), not a text field, so the launcher keeps its keyboard navigation.
///
/// Pinned to the dark appearance: the launcher is always white-on-wallpaper, and a
/// pale wallpaper would otherwise flip the glass light under white text. Text on
/// glass stays `.primary` (dimmed styles measure under 3:1 on glass); the placeholder
/// steps back through weight instead.
struct SearchBar: View {
    let query: String
    let markedText: String
    let isFocused: Bool
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 34

    /// Shared with the canvas, which hit-tests the bar itself.
    static func width(expanded: Bool, hasText: Bool) -> CGFloat {
        guard expanded else { return height }
        return hasText ? 340 : 236
    }

    private var hasText: Bool { !query.isEmpty || !markedText.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            // Resting, the lens recedes through its glyph (fading the glass itself
            // would muddy the lensing): findable, never competing with the icons.
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 14)
                .opacity(isExpanded ? 1 : 0.6)
            field
                .opacity(isExpanded ? 1 : 0)
                .blur(radius: isExpanded || reduceMotion ? 0 : 3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        // Collapsed, the lens is a circle with the magnifier centred in it.
        .padding(.leading, isExpanded ? 14 : (Self.height - 14) / 2)
        .frame(width: Self.width(expanded: isExpanded, hasText: hasText), height: Self.height, alignment: .leading)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: isExpanded)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78), value: hasText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.search)
        .accessibilityValue(query + markedText)
    }

    private var field: some View {
        HStack(spacing: 1) {
            if !query.isEmpty {
                Text(query)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !markedText.isEmpty {
                Text(markedText)
                    .underline()
                    .lineLimit(1)
                    .fixedSize()
            }
            if isFocused { Caret() }
            if !hasText {
                Text(L10n.search)
                    .fontWeight(.light)
                    .padding(.leading, 2)
                    .fixedSize()
            }
        }
        .font(.system(size: 14, weight: .regular))
    }
}

private struct Caret: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary)
            .frame(width: 1.6, height: 17)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { visible = false }
            }
    }
}
