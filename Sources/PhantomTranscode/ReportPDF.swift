import AppKit
import CoreGraphics

/// Generates an original "transcode report" PDF — one row per clip with its
/// thumbnail, source specs, trim, and output details, plus batch totals.
/// (Inspired by offload-software transfer reports; original layout.)
enum ReportPDF {

    /// One clip's line in the report.
    struct Entry {
        var filename: String
        var thumbnail: CGImage?
        var sourceW: Int
        var sourceH: Int
        var sourceFrames: Int
        var bitDepth: Int
        var isColor: Bool
        var cameraModel: String
        var serial: Int
        var recordedFps: Double
        var dateShot: Date?
        var inFrame: Int
        var outFrame: Int
        var framesUsed: Int
        var statusText: String
        var ok: Bool
        var outputName: String?
        var result: ExportResult?
    }

    struct Settings {
        var codec: String
        var resolution: String
        var quality: String
        var outputFolder: String
    }

    // Page geometry (US Letter, points).
    private static let pageW: CGFloat = 612
    private static let pageH: CGFloat = 792
    private static let margin: CGFloat = 42
    private static let rowH: CGFloat = 96

    static func generate(title: String, settings: Settings, entries: [Entry], to url: URL) -> Bool {
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return false }

        var pageNo = 0
        var y: CGFloat = 0
        func beginPage() {
            ctx.beginPDFPage(nil)
            pageNo += 1
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            drawHeader(ctx, title: title, settings: settings)
            y = pageH - 150     // content starts below the header band
        }
        func endPage() {
            drawFooter(pageNo: pageNo)
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        }

        beginPage()
        for entry in entries {
            if y - rowH < margin + 30 { endPage(); beginPage() }
            drawRow(ctx, entry: entry, topY: y)
            y -= rowH
            // separator line
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: margin, y: y + 6))
            ctx.addLine(to: CGPoint(x: pageW - margin, y: y + 6))
            ctx.strokePath()
        }

        // Totals block.
        let done = entries.filter { $0.ok }
        let totalBytes = done.compactMap { $0.result?.outputBytes }.reduce(0, +)
        let totalFrames = done.reduce(0) { $0 + $1.framesUsed }
        let totalSecs = done.compactMap { $0.result?.seconds }.reduce(0, +)
        if y - 60 < margin + 30 { endPage(); beginPage() }
        y -= 14
        drawTotals(at: y, clips: entries.count, exported: done.count,
                   frames: totalFrames, bytes: totalBytes, seconds: totalSecs)

        endPage()
        ctx.closePDF()
        return true
    }

    // MARK: drawing

    private static func drawHeader(_ ctx: CGContext, title: String, settings: Settings) {
        // Charcoal band with the app brand + a cyan play accent.
        let bandH: CGFloat = 84
        let band = CGRect(x: 0, y: pageH - bandH, width: pageW, height: bandH)
        ctx.setFillColor(NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1).cgColor)
        ctx.fill(band)
        // cyan triangle accent
        ctx.setFillColor(NSColor(red: 0.22, green: 0.78, blue: 1, alpha: 1).cgColor)
        let tx = margin, ty = pageH - bandH / 2
        ctx.move(to: CGPoint(x: tx, y: ty + 11))
        ctx.addLine(to: CGPoint(x: tx, y: ty - 11))
        ctx.addLine(to: CGPoint(x: tx + 19, y: ty))
        ctx.closePath(); ctx.fillPath()

        text(title, font: .boldSystemFont(ofSize: 18), color: .white,
             x: margin + 34, topY: pageH - 30, maxW: pageW - margin - (margin + 34))
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        text("Generated \(df.string(from: Date()))",
             font: .systemFont(ofSize: 9), color: NSColor(white: 0.75, alpha: 1),
             x: margin + 34, topY: pageH - 52, maxW: 400)

        // Settings strip under the band.
        let line = "Codec \(settings.codec)    ·    Size \(settings.resolution)    ·    Quality \(settings.quality)"
        text(line, font: .systemFont(ofSize: 10, weight: .medium), color: NSColor(white: 0.2, alpha: 1),
             x: margin, topY: pageH - bandH - 16, maxW: pageW - 2 * margin)
        text("Output: \(settings.outputFolder)", font: .systemFont(ofSize: 9),
             color: NSColor(white: 0.45, alpha: 1),
             x: margin, topY: pageH - bandH - 32, maxW: pageW - 2 * margin)
    }

    private static func drawRow(_ ctx: CGContext, entry e: Entry, topY: CGFloat) {
        let thumbW: CGFloat = 128, thumbH: CGFloat = 72
        let thumbRect = CGRect(x: margin, y: topY - thumbH - 6, width: thumbW, height: thumbH)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(thumbRect)
        if let img = e.thumbnail {
            ctx.saveGState(); ctx.clip(to: thumbRect)
            // Aspect-fill the thumbnail box.
            let ar = CGFloat(img.width) / CGFloat(img.height)
            var dw = thumbW, dh = thumbW / ar
            if dh < thumbH { dh = thumbH; dw = thumbH * ar }
            let dx = thumbRect.midX - dw / 2, dy = thumbRect.midY - dh / 2
            ctx.draw(img, in: CGRect(x: dx, y: dy, width: dw, height: dh))
            ctx.restoreGState()
        }
        ctx.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor)
        ctx.setLineWidth(0.5); ctx.stroke(thumbRect)

        let tx = margin + thumbW + 14
        let tw = pageW - margin - tx
        var ty = topY - 2

        text(e.filename, font: .boldSystemFont(ofSize: 12), color: NSColor(white: 0.1, alpha: 1),
             x: tx, topY: ty, maxW: tw); ty -= 17

        let color = "\(e.bitDepth)-bit \(e.isColor ? "color" : "mono")"
        text("Source  \(e.sourceW)×\(e.sourceH) · \(e.sourceFrames) fr · \(color) · \(Int(e.recordedFps)) fps",
             font: .systemFont(ofSize: 9.5), color: NSColor(white: 0.3, alpha: 1), x: tx, topY: ty, maxW: tw); ty -= 14

        var shot = ""
        if let d = e.dateShot { let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short; shot = "Shot \(df.string(from: d))   ·   " }
        let cam = e.cameraModel.isEmpty ? "" : "\(e.cameraModel) #\(e.serial)"
        text("\(shot)\(cam)", font: .systemFont(ofSize: 9.5), color: NSColor(white: 0.3, alpha: 1),
             x: tx, topY: ty, maxW: tw); ty -= 14

        text("Trim  \(e.inFrame)–\(e.outFrame)  (\(e.framesUsed) frames)",
             font: .systemFont(ofSize: 9.5), color: NSColor(white: 0.3, alpha: 1), x: tx, topY: ty, maxW: tw); ty -= 15

        if let r = e.result, let name = e.outputName {
            let s = String(format: "→ %@   ·   %@   ·   %d×%d   ·   %@   ·   %.0f fps   ·   %@",
                           name, r.codecName, r.width, r.height,
                           formatBytes(r.outputBytes), r.fps, r.hardware ? "hardware" : "software")
            text(s, font: .systemFont(ofSize: 9.5, weight: .medium),
                 color: NSColor(red: 0.10, green: 0.5, blue: 0.18, alpha: 1), x: tx, topY: ty, maxW: tw)
        } else {
            text(e.statusText, font: .systemFont(ofSize: 9.5, weight: .medium),
                 color: NSColor(red: 0.75, green: 0.4, blue: 0.05, alpha: 1), x: tx, topY: ty, maxW: tw)
        }
    }

    private static func drawTotals(at topY: CGFloat, clips: Int, exported: Int,
                                   frames: Int, bytes: Int, seconds: Double) {
        let box = CGRect(x: margin, y: topY - 46, width: pageW - 2 * margin, height: 44)
        NSColor(white: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text("Summary", font: .boldSystemFont(ofSize: 11), color: NSColor(white: 0.15, alpha: 1),
             x: margin + 12, topY: topY - 12, maxW: 200)
        let mins = Int(seconds) / 60, secs = Int(seconds) % 60
        let s = String(format: "%d clips exported of %d   ·   %d frames   ·   %@ written   ·   %dm %02ds",
                       exported, clips, frames, formatBytes(bytes), mins, secs)
        text(s, font: .systemFont(ofSize: 10), color: NSColor(white: 0.3, alpha: 1),
             x: margin + 12, topY: topY - 28, maxW: pageW - 2 * margin - 24)
    }

    private static func drawFooter(pageNo: Int) {
        text("Phantom Transcode   ·   page \(pageNo)", font: .systemFont(ofSize: 8),
             color: NSColor(white: 0.6, alpha: 1), x: margin, topY: margin, maxW: pageW - 2 * margin)
    }

    /// Draws a string with its top-left at (x, topY) in the unflipped PDF space.
    private static func text(_ s: String, font: NSFont, color: NSColor,
                             x: CGFloat, topY: CGFloat, maxW: CGFloat) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let bounds = attr.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let h = ceil(bounds.height)
        attr.draw(with: CGRect(x: x, y: topY - h, width: maxW, height: h),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
