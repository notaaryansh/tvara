import SwiftUI

/// Tab → deck. Vertical stack of category cards (Apps / Files / Messages
/// / Mail / Notes / Images / Clipboard) — one card per non-empty source.
/// Each card shows the count and a preview of the top hit. ↑/↓ navigates
/// cards; Enter zooms into the highlighted category; Esc pops back to the
/// blended list.
struct CategoryDeckView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        let cards = viewModel.categoryCards
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                        CategoryDeckCard(
                            card: card,
                            isSelected: idx == clamped(viewModel.selectedCardIndex, cards.count)
                        )
                        .id(card.id)
                        .onTapGesture {
                            viewModel.selectedCardIndex = idx
                            viewModel.zoomSelectedCard()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
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
}

private struct CategoryDeckCard: View {
    let card: SearchViewModel.CategoryCard
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            iconBadge

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.tab.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(card.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )
                }
                if let preview = card.topPreview {
                    Text(previewText(preview))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color.white.opacity(0.04)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor.opacity(0.55)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tint: Color { tabTint(card.tab) }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 42, height: 42)
            Image(systemName: card.tab.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func previewText(_ r: SearchResult) -> String {
        // For an app the title alone reads cleanly. For messages the
        // subtitle is the message body, which is what the user is
        // actually trying to find — surface it.
        let body = r.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = r.displayTitle
        if !body.isEmpty && body != title {
            return "\(title) — \(body)"
        }
        return title
    }
}

/// Tints align with the existing `SearchResult.Source.tint` palette so a
/// deck card and the rows it zooms into share the same color identity.
private func tabTint(_ tab: SearchTab) -> Color {
    switch tab {
    case .all:       return Color(red: 0.55, green: 0.55, blue: 0.62)
    case .messages:  return Color(red: 0.16, green: 0.72, blue: 0.35)
    case .mail:      return Color(red: 0.16, green: 0.45, blue: 0.95)
    case .apps:      return Color(red: 0.55, green: 0.40, blue: 0.95)
    case .files:     return Color(red: 0.30, green: 0.62, blue: 0.95)
    case .images:    return Color(red: 0.93, green: 0.55, blue: 0.20)
    case .clipboard: return Color(red: 0.55, green: 0.55, blue: 0.60)
    case .notes:     return Color(red: 0.98, green: 0.78, blue: 0.27)
    }
}
