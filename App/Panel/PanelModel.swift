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

    /// Top inset above the search row: the notch band (notch style) or nothing (classic).
    var topInset: CGFloat { style == .notch ? notchSize.height : 0 }
}
