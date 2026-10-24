// Renders the Phantom Transcode app icon (original art: a camera-lens ring
// with a play triangle, phantom-blue on charcoal) to a 1024px PNG.
// Run: swift make_icon.swift /tmp/icon_1024.png
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// Squircle background with a vertical charcoal gradient.
let margin: CGFloat = 24
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius: CGFloat = 226
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs,
    colors: [rgb(42, 47, 54), rgb(18, 21, 24)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

let center = CGPoint(x: S/2, y: S/2)

// Lens glass: dark radial disc.
let glassR: CGFloat = 308
ctx.saveGState()
ctx.addArc(center: center, radius: glassR, startAngle: 0, endAngle: .pi*2, clockwise: false)
ctx.clip()
let glassGrad = CGGradient(colorsSpace: cs,
    colors: [rgb(26, 44, 64), rgb(10, 14, 20)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glassGrad, startCenter: center, startRadius: 0,
                       endCenter: center, endRadius: glassR, options: [])
ctx.restoreGState()

// Lens ring: cyan→blue gradient stroke.
let ringR: CGFloat = 336
let ringW: CGFloat = 56
ctx.saveGState()
let ringPath = CGMutablePath()
ringPath.addArc(center: center, radius: ringR, startAngle: 0, endAngle: .pi*2, clockwise: false)
ctx.addPath(ringPath.copy(strokingWithWidth: ringW, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.clip()
let ringGrad = CGGradient(colorsSpace: cs,
    colors: [rgb(56, 225, 255), rgb(30, 124, 255)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ringGrad, start: CGPoint(x: center.x - ringR, y: center.y + ringR),
                       end: CGPoint(x: center.x + ringR, y: center.y - ringR), options: [])
ctx.restoreGState()

// Subtle inner highlight ring.
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(4)
ctx.addArc(center: center, radius: glassR - 6, startAngle: 0, endAngle: .pi*2, clockwise: false)
ctx.strokePath()

// Play triangle (white, slightly right of optical center for balance).
let tri = CGMutablePath()
let tw: CGFloat = 210, th: CGFloat = 240
let cx = center.x + 26, cy = center.y
tri.move(to: CGPoint(x: cx - tw*0.45, y: cy + th/2))
tri.addLine(to: CGPoint(x: cx - tw*0.45, y: cy - th/2))
tri.addLine(to: CGPoint(x: cx + tw*0.55, y: cy))
tri.closeSubpath()
ctx.saveGState()
ctx.addPath(tri.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.addPath(tri)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
