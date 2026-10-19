import AppKit
import SearchCore
import SwiftUI

/// Root of the panel window. The window frame is controlled by `LauncherPanelController`; this view
/// draws the black notch shape (or the classic floating card) at the top and animates it.
struct LauncherView: View {
    let model: PanelModel
    let query: QueryController
    let searchField: NSTextField
    let onBackgroundClick: () -> Void
    let onOpenSettings: () -> Void

    static let openSpring = Animation.spring(response: 0.36, dampingFraction: 0.78)
    static let closeSpring = Animation.spring(response: 0.28, dampingFraction: 0.95)
    static let resizeSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onBackgroundClick)
            switch model.style {
            case .notch: notchPanel
            case .classic: classicPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var contentHeight: CGFloat {
        PanelLayout.contentHeight(topInset: model.topInset, rows: query.displayedRowCount, headers: query.displayedHeaderCount)
    }

    private var content: some View {
        PanelContentView(model: model, query: query, searchField: searchField, onOpenSettings: onOpenSettings)
            .frame(width: model.panelWidth, height: contentHeight, alignment: .top)
    }

    // MARK: Notch style

    private var notchPanel: some View {
        let expanded = model.isExpanded
        let shape = NotchShape(earRadius: expanded ? PanelLayout.earRadius : 0,
                               bottomRadius: expanded ? PanelLayout.notchBottomRadius : 8)
        let width = expanded ? model.panelWidth + 2 * PanelLayout.earRadius : model.notchSize.width
        let height = expanded ? contentHeight : model.notchSize.height

        return ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 18, y: 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
                .opacity(expanded ? 1 : 0)
                .animation(expanded ? .easeOut(duration: 0.2).delay(0.07) : .easeIn(duration: 0.08), value: expanded)
        }
        .animation(Self.resizeSpring) { view in
            view.frame(width: width, height: height, alignment: .top)
        }
    }

    // MARK: Classic style

    private var classicPanel: some View {
        let expanded = model.isExpanded
        let shape = RoundedRectangle(cornerRadius: PanelLayout.classicCornerRadius, style: .continuous)
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                ZStack {
                    VisualEffectBackground()
                    Color.black.opacity(0.35)
                }
            )
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            .animation(Self.resizeSpring) { view in
                view.frame(width: model.panelWidth, height: contentHeight, alignment: .top)
            }
            .scaleEffect(expanded ? 1 : 0.96, anchor: .top)
            .opacity(expanded ? 1 : 0)
            .padding(.top, PanelLayout.shadowMargin)
    }
}

/// Search row, results list and footer, laid out at the panel's full expanded size.
struct PanelContentView: View {
    let model: PanelModel
    let query: QueryController
    let searchField: NSTextField
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.style == .notch {
                topBand
                    .frame(height: model.notchSize.height)
            }
            searchRow
                .frame(height: PanelLayout.searchRowHeight)
            if query.displayedRowCount > 0 {
                separator
                ResultsListView(query: query, commandHeld: model.commandHeld)
                    .frame(height: PanelLayout.listHeight(rows: query.displayedRowCount, headers: query.displayedHeaderCount))
            }
            separator
            FooterView(query: query, onOpenSettings: onOpenSettings)
                .frame(height: PanelLayout.footerHeight)
        }
    }

    /// The strip beside the notch: app name left, hotkey right (the notch sits in the middle).
    private var topBand: some View {
        HStack {
            Label("EmbedSearch", systemImage: "sparkle.magnifyingglass")
                .labelStyle(.titleAndIcon)
            Spacer()
            Text(model.hotKeyHint)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 22)
        .padding(.top, 2)
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            SearchFieldView(field: searchField)
                .frame(height: 28)
            if query.isFullSearchRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: PanelLayout.separatorHeight)
    }
}

struct ResultsListView: View {
    let query: QueryController
    let commandHeld: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if query.results.isEmpty {
                        placeholderRow
                    }
                    ForEach(Array(query.results.enumerated()), id: \.element.id) { index, result in
                        if index == query.settingsSectionStart {
                            SectionHeaderView(title: "설정")
                        }
                        ResultRowView(result: result, index: index, isSelected: index == query.selectedIndex,
                                      showsShortcut: commandHeld)
                            .id(result.id)
                            .onTapGesture { query.openResult(at: index) }
                    }
                }
                .padding(.vertical, PanelLayout.listVerticalPadding)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: query.selectedIndex) { _, index in
                guard query.results.indices.contains(index) else { return }
                proxy.scrollTo(query.results[index].id)
            }
            .onChange(of: query.resultsQuery) { _, _ in
                if let first = query.results.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private var placeholderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: query.isStale ? "ellipsis" : "questionmark.circle")
                .frame(width: 24)
            Text(query.isStale ? "검색 중…" : "결과 없음 — ↵ 로 다시 검색")
            Spacer()
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 10)
        .frame(height: PanelLayout.rowHeight)
    }
}

/// Title above a group of results, e.g. the settings moved below the files.
struct SectionHeaderView: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .frame(height: PanelLayout.sectionHeaderHeight, alignment: .bottom)
    }
}

struct FooterView: View {
    let query: QueryController
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(DisplayText.engineState(query.engineState))
                .foregroundStyle(.white.opacity(0.55))
                .help(stateHelp)
            if case .loadingModel(let progress) = query.engineState {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 56)
                    .tint(.white.opacity(0.6))
            }
            Spacer()
            KeyHint(key: "↵", label: query.isStale ? "검색" : "열기")
            KeyHint(key: "esc", label: query.text.isEmpty ? "닫기" : "지우기")
            SettingsButton(action: onOpenSettings)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 16)
    }

    private var stateColor: Color {
        switch query.engineState {
        case .idle: return .gray
        case .loadingModel, .indexing: return .orange
        case .ready: return .green
        case .degraded: return .yellow
        }
    }

    private var stateHelp: String {
        if case .degraded(let reason) = query.engineState { return reason }
        return DisplayText.engineState(query.engineState)
    }
}

/// Footer button that opens Settings (also ⌘,).
struct SettingsButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                Text("설정")
                Text("⌘,")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.65))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(isHovered ? 0.16 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("설정 열기 (검색 폴더, 단축키, 모양)")
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Wraps the controller-owned AppKit search field (see `LauncherFieldEditor` for why AppKit).
struct SearchFieldView: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ nsView: NSTextField, context: Context) {}
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
