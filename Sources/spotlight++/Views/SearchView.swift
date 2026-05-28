import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFocused: Bool

    private let bubbleWidth: CGFloat = 720
    private let totalWidth: CGFloat = 740
    private let totalHeight: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            bubble
            Spacer(minLength: 0)
        }
        .frame(width: totalWidth, height: totalHeight, alignment: .top)
        .background(Color.clear)
        .onAppear { isSearchFocused = true }
    }

    private var bubble: some View {
        VStack(spacing: 0) {
            // In acting mode the context "reply pill" lives ABOVE the input
            // so the visual hierarchy reads top→bottom: what you're acting
            // on → where you type → results.
            if viewModel.actingOn != nil && viewModel.composeState == nil {
                actingContextCard
            }
            searchBar
            if viewModel.composeState != nil {
                Divider().opacity(0.25)
                ComposeView(viewModel: viewModel)
            } else if viewModel.actingOn != nil {
                Divider().opacity(0.20)
                actingFooter
            } else if hasQuery {
                Divider().opacity(0.25)
                TabStripView(activeTab: $viewModel.activeTab, count: viewModel.count(for:))
                if viewModel.isAIThinking || viewModel.aiExplanation != nil {
                    aiBanner
                }
                if !viewModel.results.isEmpty {
                    Divider().opacity(0.20)
                    resultsList
                } else if !viewModel.isLoading && !viewModel.isAIThinking {
                    emptyState
                }
            }
        }
        .frame(width: bubbleWidth)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.15), value: viewModel.results.count)
        .animation(.easeOut(duration: 0.12), value: viewModel.activeTab)
    }

    private var hasQuery: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            // Keep the magnifying glass; subtle purple tint while acting
            // signals the mode change without hijacking the whole bar.
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isActing ? Color.purple.opacity(0.85) : Color.secondary)

            TextField(searchBarPlaceholder, text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($isSearchFocused)
                .disabled(viewModel.composeState != nil)

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
    }

    private var isActing: Bool {
        viewModel.actingOn != nil && viewModel.composeState == nil
    }

    private var searchBarPlaceholder: String {
        if isActing { return "Tell me what to do with this…" }
        return ""
    }

    /// iMessage-reply-pill style above the search field. Slim left accent
    /// in the source's color, neutral background, compact horizontal layout.
    /// Way calmer than the gradient version.
    private var actingContextCard: some View {
        let result = viewModel.actingOn
        let snippet = (result?.subtitle.isEmpty == false ? result!.subtitle : (result?.title ?? ""))
        // For selection-capture, prefer the original frontmost-app name
        // (e.g. "Cursor", "Slack" — apps we don't have a Source case for)
        // over the stylized Source.rawValue. Falls back to Source for
        // regular result-acting.
        let sourceName = viewModel.actingSourceDisplayName ?? (result?.source.rawValue ?? "")
        let accent = result?.source.tint ?? Color.purple

        return HStack(alignment: .center, spacing: 12) {
            // Slim left accent in the source's color.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.85))
                .frame(width: 3, height: 28)

            // Source icon for context.
            Image(systemName: result?.source.icon ?? "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.9))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("From \(sourceName)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.025))
    }

    /// Thin status-bar style footer under the input when acting, showing
    /// the keyboard hints in a quiet way (no gradient, no shouting).
    private var actingFooter: some View {
        HStack(spacing: 14) {
            shortcutHint(key: "⏎", label: "submit")
            shortcutHint(key: "esc", label: "cancel")
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { idx, result in
                        SearchResultRow(
                            result: result,
                            isSelected: idx == viewModel.selectedIndex,
                            highlightQuery: viewModel.query
                        )
                        .id(result.id)
                        .onTapGesture {
                            viewModel.selectedIndex = idx
                            viewModel.openSelected()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 440)
            .onChange(of: viewModel.selectedIndex) { _, newIdx in
                guard viewModel.results.indices.contains(newIdx) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newIdx].id, anchor: .center)
                }
            }
        }
    }

    private var aiBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [Color.purple, Color.blue],
                    startPoint: .leading, endPoint: .trailing
                ))
            if viewModel.isAIThinking {
                Text("Thinking…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else if let exp = viewModel.aiExplanation {
                Text(exp)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
