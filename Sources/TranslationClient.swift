import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

struct BaiduCredentials: Codable {
    var appID: String
    var secret: String
    var isConfigured: Bool { !appID.isEmpty && !secret.isEmpty }
}

enum TranslatorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct TranslationClient {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    static func md5(_ bytes: Data) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // Signature covers the exact binary image uploaded, not its Base64 representation.
    static func request(image: Data, mime: String, credentials: BaiduCredentials,
                        target: String, salt: String = UUID().uuidString,
                        boundary: String = "Image-" + UUID().uuidString) throws -> URLRequest {
        guard credentials.isConfigured else { throw TranslatorError.message("请先填写百度 APP ID 和密钥。") }
        let cuid = "APICUID", mac = "mac"
        let signature = md5(Data((credentials.appID + md5(image) + salt + cuid + mac + credentials.secret).utf8))
        let fields = [("from", "auto"), ("to", target), ("appid", credentials.appID),
                      ("salt", salt), ("cuid", cuid), ("mac", mac),
                      ("version", "3"), ("paste", "1"), ("sign", signature)]
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let filename = mime == "image/png" ? "selection.png" : "selection.jpg"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(image)
        append("\r\n--\(boundary)--\r\n")
        var url = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/sdk/picture")!
        url.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslatorError.message("百度返回的数据无法解析，请稍后重试。")
        }
        let code = root["error_code"].map { String(describing: $0) } ?? "0"
        guard code == "0" || code == "52000" else {
            let hint: String
            switch code {
            case "52003", "54001", "58000": hint = "请检查 APP ID、密钥，以及图片翻译服务是否已开通。"
            case "54003", "54005": hint = "请求过于频繁，请稍后再试。"
            case "54004": hint = "账户额度或余额不足，请检查百度控制台。"
            case "69002", "69003", "69004": hint = "图片未能被识别，请重新框选清晰的文字区域。"
            default: hint = "请求未完成，请在百度控制台检查服务状态。"
            }
            // Never display or log server echoes, request bodies, signatures, or credentials.
            throw TranslatorError.message("百度接口错误 \(code)。\(hint)")
        }
        var payload = root
        if let nested = root["data"] as? [String: Any] { payload = nested }
        else if let string = root["data"] as? String, let bytes = string.data(using: .utf8),
                let nested = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { payload = nested }
        guard var base64 = payload["pasteImg"] as? String, !base64.isEmpty else {
            throw TranslatorError.message("百度未返回回填图片。请确认已开通“图片翻译”服务，并重选有文字的区域。")
        }
        if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") {
            base64 = String(base64[base64.index(after: comma)...])
        }
        guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw TranslatorError.message("返回的译图无法读取。请重新框选后重试。")
        }
        // Bound decoded dimensions before allocating the bitmap.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           (width > 8192 || height > 8192 || width * height > 33_554_432) {
            throw TranslatorError.message("返回的译图尺寸异常。")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TranslatorError.message("返回的译图无法解码。")
        }
        return image
    }

    func translate(image: PreparedImage, credentials: BaiduCredentials, target: String) async throws -> CGImage {
        let request = try Self.request(image: image.data, mime: image.mime, credentials: credentials, target: target)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslatorError.message("连接百度服务失败，请检查网络后重试。")
        }
        guard data.count <= 32 * 1024 * 1024 else { throw TranslatorError.message("百度返回的数据过大。") }
        return try image.removePadding(from: Self.decode(data))
    }
}
