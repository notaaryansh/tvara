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
                if viewModel.isAIThinking || viewModel.aiExplanation != nil {
                    aiBanner
                }
                resultsArea
                if viewModel.viewMode != .blended || !viewModel.categoryCards.isEmpty {
                    statusFooter
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
        // Single binary mode token drives the bubble's resize. Each
        // discrete mode (no query, results-pending, results-shown,
        // acting, composing) maps to a stable visual shape, so the
        // animation fires exactly ONCE on mode change instead of
        // restarting on every individual count tick as results stream
        // in from per-source async tasks.
        //
        // Spring with zero overshoot — the user explicitly wants this
        // to feel snappy, not bouncy. `extraBounce: 0` keeps it crisp.
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: bubbleMode)
    }

    /// Discrete UI mode the bubble can be in. Collapses all the
    /// intermediate "got 1 result, now 2, now 3" transitions into a
    /// single "results-shown" mode so the spring fires once per real
    /// shape change, not once per source completing.
    private enum BubbleMode: String, Hashable {
        case empty            // no query typed
        case pending          // query typed, no results yet
        case results          // blended list visible
        case deck             // category deck visible
        case zoomed           // single-category zoomed list
        case acting           // acting mode footer
        case composing        // compose panel
    }

    private var bubbleMode: BubbleMode {
        if viewModel.composeState != nil { return .composing }
        if viewModel.actingOn != nil     { return .acting }
        if !hasQuery                     { return .empty }
        switch viewModel.viewMode {
        case .deck:    return .deck
        case .zoomed:  return .zoomed
        case .blended:
            if viewModel.results.isEmpty { return .pending }
            return .results
        }
    }

    /// True only when the user has typed enough characters for the
    /// ViewModel to actually run any source. Drives whether the bubble
    /// expands to show tabs + results below the input — for queries
    /// under the minimum length we keep the panel as a bare search bar,
    /// no pill strip, no empty state, no visual noise.
    private var hasQuery: Bool {
        viewModel.query.trimmingCharacters(in: .whitespaces).count
            >= SearchViewModel.minimumQueryLengthForUI
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

    /// Three discrete renderings driven by viewModel.viewMode. Wrapped in
    /// a single Group so the surrounding bubble layout doesn't change as
    /// modes switch — only the inner content does.
    @ViewBuilder
    private var resultsArea: some View {
        switch viewModel.viewMode {
        case .deck:
            CategoryDeckView(viewModel: viewModel)
        case .zoomed:
            zoomedHeader
            if !viewModel.results.isEmpty {
                resultsList
            } else if !viewModel.isLoading && !viewModel.isAIThinking {
                emptyState
            }
        case .blended:
            if !viewModel.results.isEmpty {
                resultsList
            } else if !viewModel.isLoading && !viewModel.isAIThinking {
                emptyState
            }
        }
    }

    /// Slim header when zoomed into a single category. Mirrors the
    /// active card so the user sees "I'm inside Messages" with the same
    /// icon + tint they tapped on in the deck.
    private var zoomedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.activeTab.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(viewModel.activeTab.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text("\(viewModel.results.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    /// Bottom status bar — shows the relevant keyboard hint for the
    /// current view mode. Replaces the old "⇥ to switch" tab-strip text.
    private var statusFooter: some View {
        HStack(spacing: 12) {
            switch viewModel.viewMode {
            case .blended:
                shortcutHint(key: "⇥", label: "categories")
            case .deck:
                shortcutHint(key: "↩", label: "open")
                shortcutHint(key: "esc", label: "back")
            case .zoomed:
                shortcutHint(key: "↩", label: "open")
                shortcutHint(key: "esc", label: "back to categories")
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.02))
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.activeTab == .all {
                        sectionedBlendedList
                    } else {
                        // Zoomed (single category): flat list, no headers.
                        flatList
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

    /// Flat enumeration used in zoom mode where rows aren't grouped.
    @ViewBuilder
    private var flatList: some View {
        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { idx, result in
            rowContent(result: result, idx: idx)
                .id(result.id)
        }
    }

    /// Sectioned layout for the blended (.all) view. Renders a small
    /// header above each section's content WHEN there is more than one
    /// section visible. With a single section the header is suppressed
    /// and items render as a flat list — closest to "you searched for X
    /// and only one source matched, just show that source."
    @ViewBuilder
    private var sectionedBlendedList: some View {
        let sections = viewModel.blendedSections
        let showHeaders = sections.count > 1
        ForEach(Array(sections.enumerated()), id: \.element.id) { _, section in
            if showHeaders {
                sectionHeader(
                    label: section.kind.label,
                    count: section.items.count,
                    isLoading: viewModel.loadingSections.contains(section.kind)
                )
            }
            ForEach(Array(section.items.enumerated()), id: \.element.id) { localIdx, item in
                let flatIdx = flatIndex(for: section, localIdx: localIdx, in: sections)
                // Messaging sections render in a compact one-line form
                // in the blended view. Zoom mode (per-platform tab)
                // bypasses this path and uses the full SearchResultRow.
                rowContent(result: item, idx: flatIdx, compact: section.kind.isMessageKind)
                    .id(item.id)
            }
        }
    }

    /// Map (section, localIdx) → index into the flat `viewModel.results`
    /// array, so selection highlights stay coherent. Sections appear in
    /// `blendedSections` order; flat index is the sum of preceding
    /// sections' item counts plus the local offset.
    private func flatIndex(
        for section: SearchViewModel.BlendedSection,
        localIdx: Int,
        in sections: [SearchViewModel.BlendedSection]
    ) -> Int {
        var offset = 0
        for s in sections {
            if s.kind == section.kind { return offset + localIdx }
            offset += s.items.count
        }
        return offset + localIdx
    }

    /// Slim section title above each group. Calm, secondary-tinted,
    /// small enough that it reads as chrome and doesn't compete with
    /// the row content. Mirrors the zoomedHeader style so navigating
    /// blended → zoomed feels visually continuous.
    ///
    /// When `isLoading` is true the count is hidden and a tiny inline
    /// ProgressView replaces it — that's the "results still streaming"
    /// signal per-section, so the user sees apps land while images
    /// keeps spinning instead of one big synchronized arrival.
    private func sectionHeader(label: String, count: Int, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            } else if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// One row of the blended/zoomed list. Branches on the synthetic
    /// "photo collection" row so the horizontal thumb strip replaces
    /// what would otherwise be N stacked photo rows, and on the
    /// `compact` flag which the blended view's message sections pass
    /// in to swap the full message row for a denser one-line layout.
    @ViewBuilder
    private func rowContent(result: SearchResult, idx: Int, compact: Bool = false) -> some View {
        if case .expandSection(let kindRawValue, let hidden) = result.openTarget {
            SeeMoreRow(
                hiddenCount: hidden,
                isSelected: idx == viewModel.selectedIndex
            )
            .onTapGesture {
                viewModel.selectedIndex = idx
                viewModel.toggleSectionExpanded(kindRawValue: kindRawValue)
            }
        } else if case .imagesCollection(let photos) = result.openTarget {
            PhotoCollectionRow(
                photos: photos,
                isSelected: idx == viewModel.selectedIndex,
                selectedThumbIndex: idx == viewModel.selectedIndex
                    ? viewModel.selectedThumbIndex : nil,
                onTapRow: {
                    viewModel.selectedIndex = idx
                    viewModel.selectedThumbIndex = nil
                    viewModel.zoomToImagesFromCollection()
                },
                onTapThumb: { thumbIdx in
                    viewModel.selectedIndex = idx
                    viewModel.selectedThumbIndex = thumbIdx
                    if photos.indices.contains(thumbIdx) {
                        _ = viewModel.open(photos[thumbIdx])
                    }
                }
            )
        } else if compact && Self.isMessageSource(result.source) {
            CompactMessageRow(
                result: result,
                isSelected: idx == viewModel.selectedIndex,
                highlightQuery: viewModel.query
            )
            .onTapGesture {
                viewModel.selectedIndex = idx
                viewModel.openSelected()
            }
        } else {
            SearchResultRow(
                result: result,
                isSelected: idx == viewModel.selectedIndex,
                highlightQuery: viewModel.query
            )
            .onTapGesture {
                viewModel.selectedIndex = idx
                viewModel.openSelected()
            }
        }
    }

    private static func isMessageSource(_ s: SearchResult.Source) -> Bool {
        s == .whatsapp || s == .imessage || s == .discord
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
