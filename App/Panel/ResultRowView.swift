import SearchCore
import SwiftUI

/// One Raycast-style row: icon, title, subtitle, "의미" chip, kind badge, ⌘N hint.
struct ResultRowView: View {
    let result: SearchResult
    let index: Int
    let isSelected: Bool
    let showsShortcut: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIconView(icon: result.item.icon, kind: result.item.kind)
                .frame(width: 24, height: 24)
            Text(result.item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = result.item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if DisplayText.isSemanticOnly(result.signals) {
                Text("의미")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.70, blue: 1.0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.55, green: 0.42, blue: 1.0).opacity(0.22)))
                    .help("이름은 다르지만 의미가 비슷해 찾은 결과")
            }
            Text(DisplayText.kindBadge(result.item.kind))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.38))
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
        }
    }
}
