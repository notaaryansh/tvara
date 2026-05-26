import SwiftUI

struct TabStripView: View {
    @Binding var activeTab: SearchTab
    let count: (SearchTab) -> Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SearchTab.allCases, id: \.self) { tab in
                TabPill(
                    label: tab.label,
                    count: count(tab),
                    isSelected: tab == activeTab
                )
                .contentShape(Capsule())
                .onTapGesture { activeTab = tab }
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
