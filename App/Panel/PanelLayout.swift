import CoreGraphics

enum PanelStyle: String, CaseIterable, Sendable {
    /// Black panel that springs out of the MacBook notch (or a virtual notch on other screens).
    case notch
    /// Floating Raycast-style panel, top edge at 18% of the visible height.
    case classic
}

/// Fixed metrics and pure geometry for the launcher panel. All values in points.
enum PanelLayout {
    static let searchRowHeight: CGFloat = 52
    static let rowHeight: CGFloat = 42
    static let maxVisibleRows = 8
    static let listVerticalPadding: CGFloat = 6
    static let footerHeight: CGFloat = 32
    static let separatorHeight: CGFloat = 1

    /// Concave "ear" radius where the notch panel's top edge meets the screen edge.
    static let earRadius: CGFloat = 12
    static let notchBottomRadius: CGFloat = 22
    static let classicCornerRadius: CGFloat = 18
    /// Transparent space around the shape for the shadow and spring overshoot.
    static let shadowMargin: CGFloat = 44

    static let defaultPanelWidth: CGFloat = 720
    static let panelWidthRange: ClosedRange<CGFloat> = 560...1000
    /// Virtual notch on screens without a camera housing.
    static let virtualNotchWidth: CGFloat = 185
    static let classicTopFraction: CGFloat = 0.18

    /// A section title in the result list ("설정").
    static let sectionHeaderHeight: CGFloat = 26

    /// Rows plus section headers, capped at `maxVisibleRows` rows' height (the list scrolls).
    static func listHeight(rows: Int, headers: Int = 0) -> CGFloat {
        guard rows > 0 else { return 0 }
        let full = CGFloat(rows) * rowHeight + CGFloat(headers) * sectionHeaderHeight
        return min(full, CGFloat(maxVisibleRows) * rowHeight) + 2 * listVerticalPadding
    }

    /// Height of the panel body: top inset (notch band), search row, list, footer.
    static func contentHeight(topInset: CGFloat, rows: Int, headers: Int = 0) -> CGFloat {
        let list = rows > 0 ? separatorHeight + listHeight(rows: rows, headers: headers) : 0
        return topInset + searchRowHeight + list + separatorHeight + footerHeight
    }

    static func maxContentHeight(topInset: CGFloat) -> CGFloat {
        contentHeight(topInset: topInset, rows: maxVisibleRows)
    }

    /// Notch rect in global screen coordinates (AppKit, origin bottom-left).
    /// `leftAreaWidth`/`rightAreaWidth` are the widths of `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`,
    /// `topInset` is `safeAreaInsets.top`. Returns nil when the screen has no notch.
    static func notchRect(screenFrame: CGRect, leftAreaWidth: CGFloat?, rightAreaWidth: CGFloat?,
                          topInset: CGFloat) -> CGRect? {
        guard let left = leftAreaWidth, let right = rightAreaWidth, topInset > 0 else { return nil }
        let width = screenFrame.width - left - right
        guard width > 0 else { return nil }
        return CGRect(x: screenFrame.minX + left, y: screenFrame.maxY - topInset, width: width, height: topInset)
    }

    /// Stand-in notch for screens without one: centered at the top edge, as tall as the menu bar.
    static func virtualNotchRect(screenFrame: CGRect, menuBarHeight: CGFloat) -> CGRect {
        let height = menuBarHeight > 0 ? menuBarHeight : 24
        return CGRect(x: screenFrame.midX - virtualNotchWidth / 2, y: screenFrame.maxY - height,
                      width: virtualNotchWidth, height: height)
    }

    /// Window frame for the notch style: top edge flush with the screen top, centered on the notch,
    /// tall enough for `rows` plus margins (the shape animates inside it).
    static func notchWindowFrame(notch: CGRect, screenFrame: CGRect, panelWidth: CGFloat, rows: Int,
                                 headers: Int = 0) -> CGRect {
        let width = panelWidth + 2 * earRadius + 2 * shadowMargin
        let height = contentHeight(topInset: notch.height, rows: rows, headers: headers) + shadowMargin
        return CGRect(x: notch.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Window frame for the classic style: centered horizontally, panel top at 18% of the visible height.
    static func classicWindowFrame(visibleFrame: CGRect, panelWidth: CGFloat, rows: Int, headers: Int = 0) -> CGRect {
        let width = panelWidth + 2 * shadowMargin
        let panelTop = visibleFrame.maxY - visibleFrame.height * classicTopFraction
        let height = contentHeight(topInset: 0, rows: rows, headers: headers) + 2 * shadowMargin
        return CGRect(x: visibleFrame.midX - width / 2, y: panelTop + shadowMargin - height,
                      width: width, height: height)
    }
}
