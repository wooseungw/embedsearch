import SearchCore
import SwiftUI

/// One Raycast-style row: icon, title, subtitle, "의미" chip, kind badge, ⌘N hint. A PDF found by
/// its content shows the page that matched and the words around the match instead of its folder.
struct ResultRowView: View {
    let result: SearchResult
    let index: Int
    let isSelected: Bool
    let showsShortcut: Bool
    /// The query the results are for (the excerpt's words).
    let query: String
    /// Widest a title gets next to an excerpt, so the excerpt keeps room beside a long file name.
    let titleWidthBesideExcerpt: CGFloat

    @State private var loaded: (key: PageExcerpts.Key, excerpt: PageMatch.Excerpt)?

    var body: some View {
        HStack(spacing: 10) {
            ItemIconView(icon: result.item.icon, kind: result.item.kind)
                .frame(width: 24, height: 24)
            Text(result.item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                // A file name keeps its start and its extension.
                .truncationMode(result.item.kind == .file ? .middle : .tail)
                .modifier(TitleWidth(limit: excerptKey == nil ? nil : titleWidthBesideExcerpt))
                .layoutPriority(1)
            if let subtitle {
                subtitle
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .help(excerpt.map { "\($0.page)쪽: \($0.before)\($0.match)\($0.after)" } ?? "")
            }
            Spacer(minLength: 8)
            if DisplayText.isSemanticOnly(result.signals) {
                Text("의미")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.70, blue: 1.0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.55, green: 0.42, blue: 1.0).opacity(0.22)))
                    .fixedSize()
                    .help("이름은 다르지만 의미가 비슷해 찾은 결과")
            }
            Text(DisplayText.kindBadge(result.item.kind))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize()
            if showsShortcut && index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PanelLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: excerptKey) {
            guard let key = excerptKey else { return }
            let excerpt = await PageExcerpts.shared.excerpt(key)
            if !Task.isCancelled { loaded = (key, excerpt) }
        }
    }

    private var excerptKey: PageExcerpts.Key? { PageExcerpts.key(for: result, query: query) }

    /// The excerpt for this result; while the next query's excerpt loads, the last one of the
    /// same page, so the row does not flicker back to the folder.
    private var excerpt: PageMatch.Excerpt? {
        guard let key = excerptKey else { return nil }
        if let cached = PageExcerpts.shared.cached(key) { return cached }
        guard let loaded, loaded.key.path == key.path, loaded.key.page == key.page else { return nil }
        return loaded.excerpt
    }

    private var subtitle: Text? {
        let folder = result.item.subtitle.flatMap { $0.isEmpty ? nil : Text($0) }
        guard let page = excerpt?.page ?? result.breakdown.page, excerptKey != nil else { return folder }
        let label = Text(verbatim: "p.\(page)").foregroundStyle(.white.opacity(0.62))
        guard let excerpt, !excerpt.isEmpty else { return folder.map { label + Text("  ") + $0 } ?? label }
        return label + Text(verbatim: "  \(excerpt.before)")
            + Text(verbatim: excerpt.match).foregroundStyle(.white.opacity(0.85)).fontWeight(.semibold)
            + Text(verbatim: excerpt.after)
    }
}

/// At most `limit` wide but no wider than the title needs (a bare `frame(maxWidth:)` would pad a
/// short title out to the limit); no limit: the title takes what the row gives it.
private struct TitleWidth: ViewModifier {
    let limit: CGFloat?

    func body(content: Content) -> some View {
        if let limit {
            content
                .frame(maxWidth: limit, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            content
        }
    }
}

struct ItemIconView: View {
    let icon: IconHint
    let kind: ItemKind

    var body: some View {
        switch icon {
        case .filePath(let path):
            Image(nsImage: IconCache.shared.icon(forPath: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .systemSymbol(let name):
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: tileColors, startPoint: .top, endPoint: .bottom))
                .overlay(
                    Image(systemName: name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .padding(1)
        }
    }

    private var tileColors: [Color] {
        switch kind {
        case .command: return [Color(white: 0.42), Color(white: 0.28)]
        case .shortcut: return [Color(red: 0.95, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.25, blue: 0.85)]
        case .systemSetting: return [Color(white: 0.55), Color(white: 0.35)]
        case .application: return [Color.blue, Color.indigo]
        case .file: return [Color(red: 0.35, green: 0.65, blue: 0.95), Color(red: 0.20, green: 0.45, blue: 0.80)]
        case .clipboard: return [Color(red: 0.95, green: 0.62, blue: 0.25), Color(red: 0.85, green: 0.42, blue: 0.15)]
        }
    }
}
