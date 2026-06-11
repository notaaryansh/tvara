import AppKit
import SwiftUI

/// One-row summary the blended view substitutes in place of N individual
/// photo rows whenever the Images section coexists with at least one
/// sibling section. Standalone Images-only blended views render every
/// photo as a full row — this collapse path is purely a "don't let
/// photos dominate" affordance.
///
/// Layout: just the horizontal scrollable thumb strip + a chevron at
/// the end. No icon badge, no inline title — the section header above
/// already says "Images" with the count. The whole row is clickable;
/// Enter at row-level focus zooms into Images, ← → scrubs the strip,
/// Enter on a focused thumb opens that specific photo.
struct PhotoCollectionRow: View {
    let photos: [SearchResult]
    let isSelected: Bool
    /// nil when the row itself is highlighted (no specific thumb chosen).
    /// Non-nil when ← → has moved focus into the strip.
    let selectedThumbIndex: Int?
    let onTapRow: () -> Void
    let onTapThumb: (Int) -> Void

    private static let thumbSize: CGFloat = 44
    private static let thumbGap: CGFloat = 6
    private static let stripPadEnds: CGFloat = 2
    private static let maxInlineThumbs = 8
    private static let minInlineThumbs = 3

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            thumbStrip
            chevron
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected && selectedThumbIndex == nil
                      ? Color.accentColor.opacity(0.28)
                      : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTapRow() }
    }

    /// Horizontally scrolling thumbnail strip. Width fits to the column
    /// available; thumb count clamped to [3, 8]. Each thumb is the row's
    /// own iconData (CLIP-baked thumbnail) — falls back to a tinted
    /// placeholder if the bytes are missing.
    private var thumbStrip: some View {
        GeometryReader { geo in
            let visible = visibleCount(for: geo.size.width)
            let stripWidth = CGFloat(visible) * Self.thumbSize
                + CGFloat(max(visible - 1, 0)) * Self.thumbGap
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.thumbGap) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { idx, photo in
                            thumb(for: photo, index: idx)
                                .id(idx)
                                .onTapGesture { onTapThumb(idx) }
                        }
                    }
                    .padding(.horizontal, Self.stripPadEnds)
                }
                .frame(width: stripWidth)
                .onChange(of: selectedThumbIndex) { _, newValue in
                    guard let idx = newValue else { return }
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
        .frame(height: Self.thumbSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func visibleCount(for availableWidth: CGFloat) -> Int {
        let perThumb = Self.thumbSize + Self.thumbGap
        let raw = Int(floor((availableWidth + Self.thumbGap) / perThumb))
        return min(max(raw, Self.minInlineThumbs),
                   min(Self.maxInlineThumbs, photos.count))
    }

    @ViewBuilder
    private func thumb(for photo: SearchResult, index: Int) -> some View {
        let isThumbSelected = (selectedThumbIndex == index)
        Group {
            if let data = photo.iconData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isThumbSelected
                        ? Color.accentColor
                        : Color.white.opacity(0.12),
                    lineWidth: isThumbSelected ? 2 : 0.5
                )
        )
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }
}
