import AppKit
import SwiftUI

/// Tab → category menu. One compact row per non-empty source (Apps / Files
/// / Messages / Mail / Notes / Images / Clipboard): its icon, its name, a
/// preview of the top hit, and how many results it holds. ↑/↓ moves;
/// Enter zooms into the highlighted category; Esc pops back to the blended
/// list.
///
/// Deliberately the same grammar as the result list — same row padding,
/// same type sizes, same selection highlight — so it reads as another view
/// of the results rather than a separate screen.
struct CategoryDeckView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        let cards = viewModel.categoryCards
        let selected = clamped(viewModel.selectedCardIndex, cards.count)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                        CategoryRow(
                            title: card.tab.label,
                            preview: card.topPreview.map(Self.previewText),
                            count: card.count,
                            icon: CategoryIcon(card.tab),
                            isSelected: idx == selected
                        )
                        .id(card.id)
                        .onTapGesture {
                            viewModel.selectedCardIndex = idx
                            viewModel.zoomSelectedCard()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 440)
            .onChange(of: viewModel.selectedCardIndex) { _, newIdx in
                guard cards.indices.contains(newIdx) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(cards[newIdx].id, anchor: .center)
                }
            }
        }
    }

    private func clamped(_ idx: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(idx, 0), count - 1)
    }

    /// For an app the title alone reads cleanly. For messages the subtitle
    /// is the message body, which is what the user is actually trying to
    /// find — surface it.
    private static func previewText(_ r: SearchResult) -> String {
        let body = r.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = r.displayTitle
        if !body.isEmpty && body != title {
            return "\(title) — \(body)"
        }
        return title
    }
}

/// What a category shows in its icon slot: the real app's icon when the
/// category is one app's content, otherwise a plain symbol.
enum CategoryIcon {
    case app(NSImage)
    case symbol(String)

    init(_ tab: SearchTab) {
        switch tab {
        case .mail:      self = .app(Self.mail)
        case .notes:     self = .app(Self.notes)
        case .messages:  self = .app(Self.messages)
        case .apps:      self = .symbol("square.grid.2x2")
        case .files:     self = .symbol("folder")
        case .images:    self = .symbol("photo")
        case .clipboard: self = .symbol("doc.on.clipboard")
        case .all:       self = .symbol("magnifyingglass")
        }
    }

    // Resolved on first use (the first time the menu is opened), then kept:
    // three small icons, never loaded at launch.
    private static let mail = RowRendering.appIcon(
        bundleID: "com.apple.mail", fallbackPath: "/System/Applications/Mail.app")
    private static let notes = RowRendering.appIcon(
        bundleID: "com.apple.Notes", fallbackPath: "/System/Applications/Notes.app")
    private static let messages = RowRendering.appIcon(
        bundleID: "com.apple.MobileSMS", fallbackPath: "/System/Applications/Messages.app")
}

/// One line of the category menu. Takes plain values so it can be laid out
/// and checked without a view model.
struct CategoryRow: View {
    let title: String
    let preview: String?
    let count: Int
    let icon: CategoryIcon
    let isSelected: Bool

    /// Same slot as the avatar in a compact message row.
    private static let iconSize: CGFloat = 28
    /// Fixed so every row's preview starts at the same x.
    private static let titleWidth: CGFloat = 86

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconView
                .frame(width: Self.iconSize, height: Self.iconSize)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: Self.titleWidth, alignment: .leading)

            Text(preview ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                // Fixed column, so every preview stops at the same edge.
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RowRendering.selectionBackground(isSelected))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "result" : "results")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .app(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}
