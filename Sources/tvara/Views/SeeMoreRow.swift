import SwiftUI

/// Footer row appended to a capped blended section (currently the
/// per-platform messaging sections). Tappable / Enter-able. Toggles
/// the section's expansion in SearchViewModel.expandedSections.
struct SeeMoreRow: View {
    let hiddenCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("See \(hiddenCount) more")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }
}
