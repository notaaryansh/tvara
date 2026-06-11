import AppKit
import SwiftUI

/// Dense one-line rendering for message results inside the blended
/// view. The section header above already labels the platform
/// (WhatsApp / iMessage / Discord), so the row drops the platform
/// badge on the avatar and merges sender + body onto a single line:
///
///   [avatar 28]  drishtu · what time i wakey...        9 min ago
///
/// Zoom view (per-platform tab) still uses the full SearchResultRow
/// layout — this compact form is purely for the blended-list density.
struct CompactMessageRow: View {
    let result: SearchResult
    let isSelected: Bool
    var highlightQuery: String = ""

    private static let avatarSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            avatar
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(highlightedBody)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let date = result.date {
                Text(relativeString(date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = result.iconData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        } else {
            ZStack {
                Circle().fill(placeholderColor)
                Text(initial(from: result.displayTitle))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
        }
    }

    private var placeholderColor: Color {
        let hash = result.displayTitle.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette: [Color] = [
            Color(red: 0.45, green: 0.55, blue: 0.85),
            Color(red: 0.85, green: 0.45, blue: 0.55),
            Color(red: 0.45, green: 0.80, blue: 0.65),
            Color(red: 0.85, green: 0.65, blue: 0.40),
            Color(red: 0.65, green: 0.50, blue: 0.85),
            Color(red: 0.50, green: 0.70, blue: 0.85)
        ]
        return palette[abs(hash) % palette.count]
    }

    private func initial(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Discord rows ship a senderName separate from the conversation
    /// title; prepend it bold so the eye lands on it first, like the
    /// full row does. Other platforms just show the message body.
    private var highlightedBody: AttributedString {
        let base = NSMutableAttributedString()
        var bodyOffset = 0
        if let sender = result.senderName, !sender.isEmpty {
            let prefix = "\(sender)  "
            base.append(NSAttributedString(string: prefix, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]))
            bodyOffset = prefix.count
        }
        base.append(NSAttributedString(string: result.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        let q = highlightQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return AttributedString(base) }
        let haystack = result.subtitle.lowercased()
        let needle = q.lowercased()
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            let nsRange = NSRange(found, in: haystack)
            let shifted = NSRange(location: nsRange.location + bodyOffset,
                                  length: nsRange.length)
            base.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ], range: shifted)
            cursor = found.upperBound
        }
        return AttributedString(base)
    }
}
