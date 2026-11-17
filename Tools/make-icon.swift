// Draws Kansio's app icon (an original design: a manila folder with a sheet of paper on the standard macOS
// rounded-square base) and writes App/Resources/AppIcon.icns.
//
//   swift Tools/make-icon.swift            (needs only the Command Line Tools: AppKit + iconutil)
//
// Layout follows Apple's macOS icon grid: 1024×1024 canvas, the rounded square is 824×824 at (100, 100) with a
// ~185 pt corner radius, plus a soft drop shadow — so the system shows it as a regular, full-size icon.
import AppKit

let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "App/Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Base: rounded square with a drop shadow and a soft sky gradient.
    let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.set()
    color(0xDCEBFA).setFill()
    base.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xF4F9FF), color(0xCFE2F6)])!.draw(in: base, angle: -90)
    color(0xFFFFFF, 0.6).setStroke()
    base.lineWidth = 3
    base.stroke()

    // Folder back with its tab.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 236, y: 262))
    back.line(to: NSPoint(x: 236, y: 704))
    back.curve(to: NSPoint(x: 276, y: 744), controlPoint1: NSPoint(x: 236, y: 726), controlPoint2: NSPoint(x: 254, y: 744))
    back.line(to: NSPoint(x: 432, y: 744))
    back.curve(to: NSPoint(x: 468, y: 726), controlPoint1: NSPoint(x: 448, y: 744), controlPoint2: NSPoint(x: 458, y: 738))
    back.line(to: NSPoint(x: 500, y: 690))
    back.line(to: NSPoint(x: 748, y: 690))
    back.curve(to: NSPoint(x: 788, y: 650), controlPoint1: NSPoint(x: 770, y: 690), controlPoint2: NSPoint(x: 788, y: 672))
    back.line(to: NSPoint(x: 788, y: 262))
    back.close()
    NSGradient(colors: [color(0xE7A324), color(0xD08A12)])!.draw(in: back, angle: -90)

    // A sheet of paper sticking out.
    let paper = NSBezierPath(roundedRect: NSRect(x: 278, y: 300, width: 468, height: 360), xRadius: 14, yRadius: 14)
    color(0xFFFFFF).setFill()
    paper.fill()
    color(0xB9C6D4).setFill()
    for i in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: 322, y: 594 - CGFloat(i) * 34, width: i == 2 ? 230 : 380, height: 12),
                     xRadius: 6, yRadius: 6).fill()
    }

    // Folder front, slightly narrower at the bottom for depth.
    let front = NSBezierPath()
    front.move(to: NSPoint(x: 252, y: 236))
    front.line(to: NSPoint(x: 772, y: 236))
    front.curve(to: NSPoint(x: 806, y: 268), controlPoint1: NSPoint(x: 792, y: 236), controlPoint2: NSPoint(x: 804, y: 248))
    front.line(to: NSPoint(x: 826, y: 552))
    front.curve(to: NSPoint(x: 790, y: 590), controlPoint1: NSPoint(x: 828, y: 574), controlPoint2: NSPoint(x: 812, y: 590))
    front.line(to: NSPoint(x: 234, y: 590))
    front.curve(to: NSPoint(x: 198, y: 552), controlPoint1: NSPoint(x: 212, y: 590), controlPoint2: NSPoint(x: 196, y: 574))
    front.line(to: NSPoint(x: 218, y: 268))
    front.curve(to: NSPoint(x: 252, y: 236), controlPoint1: NSPoint(x: 220, y: 248), controlPoint2: NSPoint(x: 232, y: 236))
    front.close()
    NSGraphicsContext.saveGraphicsState()
    let frontShadow = NSShadow()
    frontShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    frontShadow.shadowOffset = NSSize(width: 0, height: 6)
    frontShadow.shadowBlurRadius = 10
    frontShadow.set()
    color(0xF6C445).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFFDC6E), color(0xF3B630)])!.draw(in: front, angle: -90)
    // A light edge along the top of the front.
    let edge = NSBezierPath()
    edge.move(to: NSPoint(x: 236, y: 584))
    edge.line(to: NSPoint(x: 788, y: 584))
    edge.lineWidth = 6
    color(0xFFF1B8, 0.9).setStroke()
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "Kansio-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = draw(size: points * scale)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
if let preview = CommandLine.arguments.dropFirst().first {
    try draw(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(filePath: preview))
}
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false), "-o", output.path(percentEncoded: false)]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path(percentEncoded: false))")
