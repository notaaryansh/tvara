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
            searchBar
            if hasQuery {
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Search history, files, and folders", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($isSearchFocused)

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
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
