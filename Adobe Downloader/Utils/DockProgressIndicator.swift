//
//  DockProgressIndicator.swift
//  Adobe Downloader
//
//  Dock icon progress display
//

import Cocoa

class DockProgressIndicator {
    static let shared = DockProgressIndicator()

    private var progressView: DockProgressView?
    var taskCount: Int = 0

    private init() {}

    func update(progress: Double, taskCount: Int, speed: Double, isCompleted: Bool) {
        DispatchQueue.main.async {
            self.taskCount = taskCount

            if taskCount > 0 {
                NSApp.dockTile.badgeLabel = Self.formatSpeed(speed)
                self.updateCustomProgress(
                    progress,
                    taskCount: taskCount,
                    isCompleted: false
                )
                return
            }

            NSApp.dockTile.badgeLabel = nil
            if isCompleted {
                self.updateCustomProgress(
                    1,
                    taskCount: 0,
                    isCompleted: true
                )
            } else {
                self.clearNow()
            }
        }
    }

    func updateProgress(_ progress: Double) {
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = nil
            guard self.taskCount > 0 else {
                if progress >= 0.999 {
                    self.clearNow()
                }
                return
            }
            self.updateCustomProgress(
                progress,
                taskCount: self.taskCount,
                isCompleted: false
            )
        }
    }

    private func updateCustomProgress(
        _ progress: Double,
        taskCount: Int,
        isCompleted: Bool
    ) {
        if progressView == nil {
            let iconSize = NSApp.dockTile.size
            progressView = DockProgressView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
            NSApp.dockTile.contentView = progressView
        }

        progressView?.progress = min(max(progress, 0), 1)
        progressView?.taskCount = taskCount
        progressView?.isCompleted = isCompleted
        NSApp.dockTile.display()
    }

    func clear() {
        DispatchQueue.main.async {
            self.clearNow()
        }
    }

    private func clearNow() {
        taskCount = 0
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.contentView = nil
        progressView = nil
        NSApp.dockTile.display()
    }

    private static func formatSpeed(_ speed: Double) -> String? {
        guard speed > 0 else { return nil }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = speed
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }

        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private class DockProgressView: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var taskCount: Int = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var isCompleted: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let appIcon = NSApp.applicationIconImage {
            appIcon.draw(in: bounds)
        }

        let diameter = min(bounds.width, bounds.height) * 0.36
        let margin = min(bounds.width, bounds.height) * 0.08
        let lineWidth = max(diameter * 0.1, 4)
        let radius = (diameter - lineWidth) / 2
        let circleRect = NSRect(
            x: bounds.width - diameter - margin,
            y: margin,
            width: diameter,
            height: diameter
        )
        let center = CGPoint(x: circleRect.midX, y: circleRect.midY)

        context.saveGState()

        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: 4,
            color: NSColor.black.withAlphaComponent(0.45).cgColor
        )

        let fillPath = NSBezierPath(ovalIn: circleRect)
        (isCompleted ? NSColor.systemGreen : NSColor.black.withAlphaComponent(0.55)).setFill()
        fillPath.fill()

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        if isCompleted {
            let checkPath = NSBezierPath()
            checkPath.lineWidth = max(lineWidth * 1.2, 5)
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            checkPath.move(to: CGPoint(x: center.x - diameter * 0.16, y: center.y - diameter * 0.02))
            checkPath.line(to: CGPoint(x: center.x - diameter * 0.04, y: center.y - diameter * 0.14))
            checkPath.line(to: CGPoint(x: center.x + diameter * 0.2, y: center.y + diameter * 0.16))
            NSColor.white.setStroke()
            checkPath.stroke()
            context.restoreGState()
            return
        }

        let strokeRect = circleRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let backgroundPath = NSBezierPath(ovalIn: strokeRect)
        backgroundPath.lineWidth = lineWidth
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        backgroundPath.stroke()

        context.setStrokeColor(NSColor.systemBlue.cgColor)
        if progress >= 0.999 {
            let progressPath = NSBezierPath(ovalIn: strokeRect)
            progressPath.lineWidth = lineWidth
            progressPath.stroke()
        } else if progress > 0 {
            let startAngle = CGFloat.pi / 2
            let endAngle = startAngle - (.pi * 2 * progress)
            let progressPath = CGMutablePath()
            progressPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            context.addPath(progressPath)
            context.strokePath()
        }

        let text = taskCount > 99 ? "99+" : "\(taskCount)"
        let fontSize: CGFloat = text.count > 2 ? 13 : 18
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )

        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        text.draw(in: textRect, withAttributes: attributes)

        context.restoreGState()
    }
}
