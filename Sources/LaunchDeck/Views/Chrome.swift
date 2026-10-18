import AppKit
import SwiftUI

/// The bits of launcher state the SwiftUI search bar renders.
final class ChromeState: ObservableObject {
    @Published var query = ""
    @Published var isShown = false
    /// True while a folder is open; the search bar steps aside.
    @Published var hidesChrome = false
}

/// Hosts the search bar without taking clicks; the canvas handles all input.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SearchBarContainer: View {
    @ObservedObject var state: ChromeState

    var body: some View {
        let visible = state.isShown && !state.hidesChrome
        SearchBar(query: state.query, isActive: visible)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -12)
            .animation(visible ? .spring(response: 0.5, dampingFraction: 0.82).delay(0.05) : .easeIn(duration: 0.16),
                       value: visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Liquid Glass search capsule. Text comes from the key monitor, not a text field,
/// so input methods never pop a candidate window over the launcher.
struct SearchBar: View {
    let query: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 1) {
                if !query.isEmpty {
                    Text(query)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if isActive { Caret() }
                if query.isEmpty {
                    Text(L10n.search)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 2)
                }
            }
            .font(.system(size: 14, weight: .regular))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: query.isEmpty ? 236 : 340, height: 34)
        .background(Capsule().fill(.white.opacity(0.06)))
        .glassEffect(.regular, in: Capsule())
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: query.isEmpty)
    }
}

private struct Caret: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white)
            .frame(width: 1.6, height: 17)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { visible = false }
            }
    }
}
