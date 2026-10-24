import AppKit
import ScreenCaptureKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionCoordinator {
    private var panels: [OverlayPanel] = []
    var onSelection: ((CGImage, CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var cancelled = false

    func begin() async throws {
        cancelled = false
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [(CGRect, CGImage)] = []
        // Capture before showing any overlays, so selections never include our own UI.
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            let frame = screen.frame
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = available.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let ownApps = available.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
            config.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if UserDefaults.standard.bool(forKey: "captureDiagnosticsEnabled") {
                // Diagnostics contain only dimensions/counts, never screen content or window titles.
                UserDefaults.standard.set(["method": "display-filter", "width": image.width, "height": image.height,
                                           "displays": available.displays.count, "windows": available.windows.count,
                                           "applications": available.applications.count], forKey: "captureDiagnostics")
            }
            snapshots.append((frame, image))
        }
        guard !snapshots.isEmpty else { throw TranslatorError.message("未找到可截图的显示器。") }
        try Task.checkCancellation()
        guard !cancelled else { return }
        NSApp.activate(ignoringOtherApps: true)
        for (frame, image) in snapshots {
            let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let view = SelectionView(image: image, size: frame.size)
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelection = { [weak self] rect in
                guard let self else { return }
                let pixels = ImagePipeline.pixelRect(selection: rect, viewSize: frame.size,
                                                     imageSize: CGSize(width: image.width, height: image.height))
                guard let cropped = image.cropping(to: pixels) else { self.cancel(); return }
                let screenRect = ImagePipeline.screenRect(selection: rect, screenFrame: frame)
                self.dismiss()
                self.onSelection?(cropped, screenRect)
            }
            panel.contentView = view; panel.orderFrontRegardless(); panel.makeFirstResponder(view)
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation
        let active = panels.first(where: { $0.frame.contains(mouse) }) ?? panels.first
        active?.makeKeyAndOrderFront(nil)
    }
    func dismiss() {
        for panel in panels { panel.orderOut(nil); panel.contentView = nil }
        panels.removeAll()
    }
    func cancel() { cancelled = true; dismiss(); onCancel?() }
}

final class SelectionView: NSView {
    private let snapshot: NSImage
    private var start: CGPoint?
    private var selection = CGRect.zero
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage, size: CGSize) {
        snapshot = NSImage(cgImage: image, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        snapshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let mask = NSBezierPath(rect: bounds)
        if !selection.isEmpty { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.40).setFill(); mask.fill()
        if !selection.isEmpty {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1.5; outline.stroke()
        }
        let text = selection.isEmpty ? "拖动框选要翻译的区域 · Esc 取消" : "\(Int(selection.width)) × \(Int(selection.height)) · 松开翻译 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = selection.isEmpty ? CGPoint(x: (bounds.width - size.width) / 2, y: 44) :
            CGPoint(x: min(max(12, selection.minX), bounds.maxX - size.width - 24), y: min(selection.maxY + 12, bounds.maxY - 42))
        let badge = CGRect(x: origin.x - 10, y: origin.y - 7, width: size.width + 20, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = point(event); selection = .zero; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }; let current = point(event)
        selection = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                           width: abs(start.x - current.x), height: abs(start.y - current.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 8, selection.height >= 8 else { start = nil; selection = .zero; needsDisplay = true; return }
        onSelection?(selection)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }
}

@MainActor
final class TranslationOverlay {
    private let panel: OverlayPanel
    private let toolbar: NSPanel
    private let imageView: ResultImageView
    private let label = NSTextField(labelWithString: "正在翻译… · Esc 取消")
    private var original: NSImage?
    private var translated: NSImage?
    var onClose: (() -> Void)?

    init(image: CGImage, rect: CGRect) {
        original = NSImage(cgImage: image, size: rect.size)
        panel = OverlayPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.hasShadow = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        imageView = ResultImageView(frame: CGRect(origin: .zero, size: rect.size))
        imageView.imageScaling = .scaleAxesIndependently; imageView.image = original
        imageView.wantsLayer = true; imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        panel.contentView = imageView
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        let width = min(300, visible.width)
        let barRect = CGRect(x: min(max(rect.minX, visible.minX), visible.maxX - width),
                             y: min(rect.maxY + 7, visible.maxY - 34), width: width, height: 34)
        toolbar = NSPanel(contentRect: barRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.level = .floating; toolbar.isOpaque = false; toolbar.backgroundColor = .clear
        toolbar.hasShadow = true; toolbar.isReleasedWhenClosed = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(); background.material = .hudWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 9
        toolbar.contentView = background
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!, target: self, action: #selector(closeClicked))
        close.isBordered = false; close.toolTip = "关闭译图（Esc）"
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        for view in [label, close] { view.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(view) }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
                                     label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                                     label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
                                     close.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
                                     close.centerYAnchor.constraint(equalTo: background.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 20)])
        imageView.onEscape = { [weak self] in self?.onClose?() }
        imageView.onSpace = { [weak self] pressed in
            guard let self, self.translated != nil else { return }
            self.imageView.image = pressed ? self.original : self.translated
        }
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(imageView); toolbar.orderFrontRegardless()
    }
    func complete(_ image: CGImage, elapsed: TimeInterval) {
        translated = NSImage(cgImage: image, size: panel.frame.size)
        imageView.image = translated
        label.stringValue = String(format: "%.1f 秒 · 按住空格看原图 · Esc 关闭", elapsed)
    }
    func dismiss() {
        panel.orderOut(nil); toolbar.orderOut(nil); imageView.image = nil
        original = nil; translated = nil
        panel.contentView = nil; toolbar.contentView = nil
    }
    @objc private func closeClicked() { onClose?() }
}

final class ResultImageView: NSImageView {
    var onEscape: (() -> Void)?
    var onSpace: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.keyCode == 49 { onSpace?(true) }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { onSpace?(false) } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
