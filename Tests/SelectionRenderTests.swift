import AppKit

@main
struct SelectionRenderTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let view = SelectionView(image: context.makeImage()!, size: CGSize(width: 640, height: 360))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let color = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        print("Selection backdrop sample:",color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent)
        precondition(color.redComponent > 0.4 && color.alphaComponent > 0.95, "The screenshot must remain visible under the selection mask")
        print("Selection background renders correctly from a known white screenshot")
    }
}
