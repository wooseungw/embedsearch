import CoreGraphics
import Observation

/// Presentation state of the panel that isn't query state: style, geometry of the notch it grows
/// from, and whether it is (animating) open.
@MainActor
@Observable
final class PanelModel {
    var style: PanelStyle = .notch
    /// Size of the (real or virtual) notch the panel grows from; its height is the top band.
    var notchSize = CGSize(width: PanelLayout.virtualNotchWidth, height: 32)
    var panelWidth: CGFloat = PanelLayout.defaultPanelWidth
    var isExpanded = false
    var commandHeld = false
    var hotKeyHint = KeyCombo.default.displayString
    /// A short confirmation the footer shows in place of the engine state ("경로를 복사했습니다").
    var notice: String?
    /// The file preview below the panel is open (⌘Y).
    var isPreviewing = false
    /// Why the clipboard history records nothing (off, or macOS denies reading), for its mode.
    var clipboardProblem: String?

    /// Top inset above the search row: the notch band (notch style) or nothing (classic).
    var topInset: CGFloat { style == .notch ? notchSize.height : 0 }
}
