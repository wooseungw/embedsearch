// Generates App/Resources/Assets.xcassets/AppIcon.appiconset (dark squircle, notch, violet
// sparkle-magnifying-glass). Run: arch -arm64 swift scripts/make-icon.swift [output.appiconset]
import AppKit

let output = CommandLine.arguments.dropFirst().first
    ?? "App/Resources/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Apple icon grid: 824×824 body centered in 1024, ~185 corner radius.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedWhite: 0.16, alpha: 1), NSColor(calibratedWhite: 0.03, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
    squircle.lineWidth = 4
    squircle.stroke()

    // The notch the launcher grows out of.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let notch = NSBezierPath(roundedRect: NSRect(x: 512 - 170, y: 924 - 96, width: 340, height: 140),
                             xRadius: 44, yRadius: 44)
    NSColor.black.setFill()
    notch.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Symbol filled with a violet → blue gradient.
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = NSRect(x: 512 - size.width / 2, y: 470 - size.height / 2, width: size.width, height: size.height)
        if let context = NSGraphicsContext.current?.cgContext {
            // Symbol in its own layer, then the gradient composited "source in" onto it.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect)
            context.setBlendMode(.sourceIn)
            NSGradient(colors: [NSColor(calibratedRed: 0.80, green: 0.62, blue: 1.0, alpha: 1),
                                NSColor(calibratedRed: 0.38, green: 0.55, blue: 1.0, alpha: 1)])!
                .draw(in: rect, angle: -60)
            context.endTransparencyLayer()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                          (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for spec in specs {
    let name = "icon_\(spec.points)x\(spec.points)\(spec.scale == 2 ? "@2x" : "").png"
    try render(pixels: spec.points * spec.scale).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    images.append(["idiom": "mac", "size": "\(spec.points)x\(spec.points)", "scale": "\(spec.scale)x",
                   "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(output)/Contents.json"))
print("wrote \(specs.count) icons to \(output)")
