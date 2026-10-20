import AppKit
import ImageIO
import PDFKit
import SearchCore
import SwiftUI

/// The preview below the launcher (⌘Y) for the selected file: a PDF at the page that matched with
/// the query's words highlighted, or an image. It follows the selection while open.
@MainActor
final class FilePreviewController {
    struct Target: Equatable {
        let path: String
        let title: String
        let folder: String?
        /// The page the match starts on (`ScoreBreakdown.page`); nil: from the first page.
        let page: Int?
        let words: [String]
        let isImage: Bool
    }

    private let panel = PreviewPanel()
    private let model = FilePreviewModel()
    private var target: Target?
    /// The open PDF, kept while only the words or the page change (typing with the preview open).
    private var document: (path: String, document: PDFDocument)?
    private var loadTask: Task<Void, Never>?
    /// The PDF `loadTask` is opening.
    private var openingPath: String?

    init() {
        let hosting = NSHostingView(rootView: FilePreviewView(model: model))
        hosting.sizingOptions = [] // the controller owns the frame
        panel.contentView = hosting
    }

    /// What the preview shows for `result`, or nil when it has no file to show.
    static func target(for result: SearchResult, query: String) -> Target? {
        guard result.item.kind == .file, case .openFile(let path) = result.item.action else { return nil }
        return Target(path: path, title: result.item.title, folder: result.item.subtitle, page: result.breakdown.page,
                      words: PageMatch.words(query), isImage: FileScanner.isImage(path: path))
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ target: Target, frame: CGRect) {
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if needsLoad(target) {
            load(target)
        } else {
            self.target = target
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
    }

    func move(to frame: CGRect) {
        guard panel.isVisible, panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Hides the panel and lets go of the file (a PDF's pages and caches, an image's pixels).
    func hide() {
        loadTask?.cancel()
        loadTask = nil
        openingPath = nil
        target = nil
        document = nil
        model.content = .none
        panel.orderOut(nil)
    }

    /// An image depends only on its file; a PDF also on the page and words (its highlights).
    private func needsLoad(_ new: Target) -> Bool {
        guard let current = target, current.path == new.path else { return true }
        return !new.isImage && (new.page != current.page || new.words != current.words)
    }

    private func load(_ target: Target) {
        let stillOpening = !target.isImage && openingPath == target.path
        self.target = target
        model.title = target.title
        // The open under way finds the words of the target current when it is done.
        if stillOpening { return }
        loadTask?.cancel()
        loadTask = nil
        openingPath = nil
        if !target.isImage, let open = document, open.path == target.path {
            // Same PDF, other words or page: PDFKit keeps the pages' text, so this is quick.
            present(open.document, target: target, match: Self.match(in: open.document, target))
            return
        }
        document = nil
        model.detail = target.folder ?? ""
        model.content = .loading
        model.generation += 1
        let path = target.path
        if target.isImage {
            loadTask = Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    autoreleasepool { PageMatch.isLocal(path) ? Self.thumbnail(path, maxPixels: 1600) : nil }
                }.value
                guard let self, !Task.isCancelled, self.target?.path == path else { return }
                self.model.content = image.map { .image(NSImage(cgImage: $0, size: .zero)) } ?? .unreadable
                self.model.generation += 1
            }
            return
        }
        // Opening a PDF and reading its pages' text takes long enough to stall typing: off the
        // main thread, which only gets the result.
        openingPath = path
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedPDF? in
                autoreleasepool {
                    guard PageMatch.isLocal(path), let pdf = PDFDocument(url: URL(filePath: path)), !pdf.isLocked else {
                        return nil
                    }
                    return LoadedPDF(document: pdf, match: Self.match(in: pdf, target))
                }
            }.value
            guard let self, !Task.isCancelled, let current = self.target, current.path == path else { return }
            self.openingPath = nil
            guard let loaded else {
                self.model.content = .unreadable
                return
            }
            self.document = (path, loaded.document)
            // The words or page changed while it was loading: find them again.
            let match = current == target ? loaded.match : Self.match(in: loaded.document, current)
            self.present(loaded.document, target: current, match: match)
        }
    }

    /// A PDF opened on a worker thread; from then on it is used on the main thread only.
    private struct LoadedPDF: @unchecked Sendable {
        let document: PDFDocument
        let match: Match
    }

    /// The page to show (1-based) and where the words are on it.
    struct Match: Sendable {
        let page: Int
        let ranges: [NSRange]
    }

    /// The first page from the target's page on that has its words, else that page.
    nonisolated static func match(in pdf: PDFDocument, _ target: Target) -> Match {
        let page = min(max(target.page ?? 1, 1), max(pdf.pageCount, 1))
        guard let found = PageMatch.firstMatch(in: pdf, words: target.words, from: page) else {
            return Match(page: page, ranges: [])
        }
        return Match(page: found.page, ranges: found.ranges)
    }

    private func present(_ pdf: PDFDocument, target: Target, match: Match) {
        var highlights: [PDFSelection] = []
        if !match.ranges.isEmpty, let page = pdf.page(at: match.page - 1) {
            highlights = match.ranges.compactMap { page.selection(for: $0) }
            for selection in highlights { selection.color = .systemYellow }
        }
        model.detail = "\(match.page) / \(pdf.pageCount)쪽"
        model.content = .pdf(pdf, page: match.page, highlights: highlights)
        model.generation += 1
    }

    /// Decoded with EXIF orientation applied, at most `maxPixels` on the long side.
    nonisolated static func thumbnail(_ path: String, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

@MainActor
@Observable
final class FilePreviewModel {
    enum Content {
        case none
        case loading
        case unreadable
        case pdf(PDFDocument, page: Int, highlights: [PDFSelection])
        case image(NSImage)
    }

    var title = ""
    /// "12 / 30쪽" for a PDF, the folder for an image.
    var detail = ""
    var content: Content = .none
    /// Bumped with every new content, so the PDF view goes to the page and highlights again.
    var generation = 0
}

/// Borderless and non-activating like the launcher, but it never becomes key: typing stays in the
/// search field, and the launcher (which closes when it loses key status) stays open.
final class PreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct FilePreviewView: View {
    let model: FilePreviewModel

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 8)
                KeyHint(key: "⌘Y", label: "닫기")
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .none:
            Color.clear
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .unreadable:
            Text("미리 볼 수 없는 파일입니다")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
        case .pdf(let document, let page, let highlights):
            PDFPreview(document: document, page: page, highlights: highlights, generation: model.generation)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(12)
        }
    }
}

/// PDFKit's view at `page`, scrolled to the first highlight.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let highlights: [PDFSelection]
    let generation: Int

    final class Coordinator {
        var applied = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.1, alpha: 1)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.applied != generation else { return }
        context.coordinator.applied = generation
        if view.document !== document { view.document = document }
        view.highlightedSelections = highlights
        guard let target = document.page(at: page - 1) else { return }
        let first = highlights.first?.bounds(for: target)
        // A view that has not been laid out at its size yet cannot scroll; go there after it has.
        Task { @MainActor in
            view.layoutDocumentView()
            if let first {
                view.go(to: first.insetBy(dx: -40, dy: -160), on: target)
            } else {
                view.go(to: target)
            }
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        view.document = nil
    }
}
