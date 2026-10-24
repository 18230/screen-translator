import AppKit
import CoreGraphics

struct PreparedImage {
    let data: Data
    let mime: String
    let contentRect: CGRect // Normalized coordinates; padding is symmetric.

    func removePadding(from image: CGImage) throws -> CGImage {
        let rect = CGRect(x: contentRect.minX * CGFloat(image.width),
                          y: contentRect.minY * CGFloat(image.height),
                          width: contentRect.width * CGFloat(image.width),
                          height: contentRect.height * CGFloat(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: rect) else { throw TranslatorError.message("无法裁剪返回的译图。") }
        return cropped
    }
}

enum ImagePipeline {
    static func prepare(_ image: CGImage) throws -> PreparedImage {
        let sourceW = CGFloat(image.width), sourceH = CGFloat(image.height)
        // The API requires dimensions >=30px, <=4096px and aspect ratio <=3:1.
        // Symmetric padding supports thin UI labels without stretching their text.
        let canvasW = max(30, sourceW, sourceH / 3)
        let canvasH = max(30, sourceH, sourceW / 3)
        var factor = min(1, 4096 / max(canvasW, canvasH))
        for _ in 0..<4 {
            try Task.checkCancellation()
            let w = max(30, Int(ceil(canvasW * factor)))
            let h = max(30, Int(ceil(canvasH * factor)))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw TranslatorError.message("无法处理截图，请缩小选区重试。")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let fitted = CGRect(x: (CGFloat(w) - sourceW * factor) / 2,
                                y: (CGFloat(h) - sourceH * factor) / 2,
                                width: sourceW * factor, height: sourceH * factor)
            context.interpolationQuality = .high
            context.draw(image, in: fitted)
            guard let rendered = context.makeImage() else { throw TranslatorError.message("截图处理失败。") }
            let bitmap = NSBitmapImageRep(cgImage: rendered)
            let content = CGRect(x: fitted.minX / CGFloat(w), y: fitted.minY / CGFloat(h),
                                 width: fitted.width / CGFloat(w), height: fitted.height / CGFloat(h))
            if let png = bitmap.representation(using: .png, properties: [:]), png.count < 4_000_000 {
                return PreparedImage(data: png, mime: "image/png", contentRect: content)
            }
            for quality in [0.9, 0.75, 0.55] {
                try Task.checkCancellation()
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count < 4_000_000 {
                    return PreparedImage(data: jpeg, mime: "image/jpeg", contentRect: content)
                }
            }
            factor *= 0.7
        }
        throw TranslatorError.message("截图过大，请缩小选区重试。")
    }

    static func pixelRect(selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        CGRect(x: selection.minX / viewSize.width * imageSize.width,
               y: selection.minY / viewSize.height * imageSize.height,
               width: selection.width / viewSize.width * imageSize.width,
               height: selection.height / viewSize.height * imageSize.height).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func screenRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + selection.minX, y: screenFrame.maxY - selection.maxY,
               width: selection.width, height: selection.height)
    }
}
