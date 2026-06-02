import SwiftUI

struct TabStripView: View {
    /// Observing the ViewModel directly (vs taking a closure parameter)
    /// is intentional. SwiftUI can't diff closures, so a previous design
    /// that passed `count: (SearchTab) -> Int` left the pill badges
    /// stale — they only refreshed when activeTab changed because the
    /// binding was the only observable input. With @ObservedObject,
    /// SwiftUI re-renders this view on every @Published change in the
    /// ViewModel, so counts always match what allMerged() returns.
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SearchTab.allCases, id: \.self) { tab in
                TabPill(
                    label: tab.label,
                    count: viewModel.count(for: tab),
                    isSelected: tab == viewModel.activeTab
                )
                .contentShape(Capsule())
                .onTapGesture { viewModel.activeTab = tab }
            }
            Spacer()
            Text("⇥ to switch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct TabPill: View {
    let label: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isSelected
                                ? Color.white.opacity(0.22)
                                : Color.white.opacity(0.08)
                        )
                    )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background(
            Capsule().fill(
                isSelected
                    ? Color.accentColor.opacity(0.32)
                    : Color.white.opacity(0.04)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected
                    ? Color.accentColor.opacity(0.55)
                    : Color.white.opacity(0.10),
                lineWidth: 1
            )
        )
    }
}
