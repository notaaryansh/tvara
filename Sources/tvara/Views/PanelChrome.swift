import SwiftUI

/// The parts of the search panel that stay the same at every level: the
/// footer bar and the scope chip in the search field.
///
/// tvara has several levels (all results → categories → one category, plus
/// acting on a result). Each used to have its own header and its own row of
/// key hints, in different styles and positions. These two views give every
/// level the same frame: the chip says which level you are in, the footer's
/// left side says what you are looking at, and its right side says what the
/// keys do right now.
///
/// Both take plain values, so they can be laid out without a view model.

/// One key and what it does, e.g. `↩ Open chat`.
struct KeyHint: Equatable, Identifiable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// Bottom bar of the panel: where you are on the left, what the keys do on
/// the right.
struct PanelFooter: View {
    /// What the list above is showing, e.g. "All results", "Messages".
    let location: String
    /// Number of rows in that list; nil hides the count.
    var count: Int? = nil
    var isLoading: Bool = false
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(location)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count.map { "\(location), \($0) results" } ?? location)

            Spacer(minLength: 12)

            HStack(spacing: 14) {
                ForEach(hints) { hint in
                    HStack(spacing: 5) {
                        Text(hint.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(hint.key)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 17)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hint.label), \(KeyHint.spoken(hint.key))")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        // No fill of its own: the footer sits directly on the panel's glass,
        // separated from the list by a hairline only.
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

extension KeyHint {
    /// VoiceOver reads the bare glyphs unreliably; spell them out.
    static func spoken(_ key: String) -> String {
        switch key {
        case "↩": return "Return"
        case "⇥": return "Tab"
        case "esc": return "Escape"
        default: return key
        }
    }
}

/// Pill at the start of the search field naming the level you are in
/// ("Categories", "Messages"). Absent at the top level.
struct ScopeChip: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching in \(label)")
    }
}

/// Shown in place of the list when a search finds nothing.
struct NoResultsView: View {
    let query: String
    /// Extra line under the title, e.g. how to widen the search.
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("No results for “\(query)”")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 34)
    }
}

extension SearchResult {
    /// What pressing Return does to this result, as a short verb phrase for
    /// the footer.
    var primaryActionLabel: String {
        switch openTarget {
        case .whatsappChat, .imessageChat: return "Open chat"
        case .copyToClipboard:             return "Copy"
        case .notesNote:                   return "Open note"
        case .spotifyPlay:                 return "Play"
        case .windowAction:                return "Move window"
        case .systemAction:                return "Run"
        case .imagesCollection:            return "Show photos"
        case .expandSection:               return "Show more"
        case .file:                        return source == .app ? "Open app" : "Open"
        case .url:
            switch source {
            case .discord:  return "Open chat"
            case .mail:     return "Open email"
            case .settings: return "Open settings"
            default:        return "Open"
            }
        }
    }
}
