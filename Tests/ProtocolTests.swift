import AppKit
import Foundation

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main
struct ProtocolTests {
    static var count = 0
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TranslatorError.message("FAIL: " + label) }
        count += 1; print("PASS: " + label)
    }
    static func mustThrow(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; print("PASS: " + label); return }
        throw TranslatorError.message("FAIL: " + label)
    }
    static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }
    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    static func main() async throws {
        let credentials = BaiduCredentials(appID: "123", secret: "a-secret-never-transmitted")
        let bytes = Data("imagebytes".utf8)
        let request = try TranslationClient.request(image: bytes, mime: "image/png", credentials: credentials,
                                                    target: "zh", salt: "salt", boundary: "test-boundary")
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        try check(request.httpMethod == "POST" && request.url?.host == "fanyi-api.baidu.com", "HTTPS image endpoint")
        try check(fields["sign"] == "437a39f79a08f794639530f87252021c", "signature matches independent Python MD5 fixture")
        try check(fields["paste"] == "1" && fields["version"] == "3" && fields["from"] == "auto", "request complete in-image translation")
        try check(!request.url!.absoluteString.contains(credentials.secret) && request.httpBody!.range(of: Data(credentials.secret.utf8)) == nil,
                  "secret absent from transmitted query/body")
        try check(request.httpBody!.range(of: bytes) != nil && request.httpBody!.suffix(21) == Data("\r\n--test-boundary--\r\n".utf8).suffix(21), "multipart carries original image bytes and closing boundary")
        try mustThrow("missing credentials rejected before network") {
            _ = try TranslationClient.request(image: bytes, mime: "image/png", credentials: BaiduCredentials(appID: "", secret: ""), target: "zh")
        }
        let picture = image(width: 200, height: 80)
        let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])!
        for shape in 0..<3 {
            let payload: [String: Any]
            if shape == 0 { payload = ["error_code": "0", "data": ["pasteImg": png.base64EncodedString()]] }
            else if shape == 1 { payload = ["error_code": 0, "data": String(data: try json(["pasteImg": png.base64EncodedString()]), encoding: .utf8)!] }
            else { payload = ["pasteImg": "data:image/png;base64," + png.base64EncodedString()] }
            let decoded = try TranslationClient.decode(json(payload))
            try check(decoded.width == 200 && decoded.height == 80, "decode response variant \(shape)")
        }
        try mustThrow("server authentication error surfaced") { _ = try TranslationClient.decode(json(["error_code": "54001", "error_msg": "echo-secret"])) }
        try mustThrow("missing translated image rejected") { _ = try TranslationClient.decode(json(["error_code": 0, "data": ["sumDst": "hello"]])) }
        try mustThrow("invalid translated bitmap rejected") { _ = try TranslationClient.decode(json(["pasteImg": Data("bad".utf8).base64EncodedString()])) }
        for (w, h) in [(1, 1), (6000, 50), (50, 6000), (800, 600)] {
            let prepared = try ImagePipeline.prepare(image(width: w, height: h))
            let bitmap = NSBitmapImageRep(data: prepared.data)!
            try check(bitmap.pixelsWide <= 4096 && bitmap.pixelsHigh <= 4096 && min(bitmap.pixelsWide, bitmap.pixelsHigh) >= 30,
                      "API dimensions for \(w)×\(h)")
            let ratio = Double(max(bitmap.pixelsWide, bitmap.pixelsHigh)) / Double(min(bitmap.pixelsWide, bitmap.pixelsHigh))
            try check(ratio <= 3.001 && prepared.data.count < 4_000_000, "aspect/size limit for \(w)×\(h)")
            let cropped = try prepared.removePadding(from: bitmap.cgImage!)
            let restoredRatio = Double(cropped.width) / Double(cropped.height)
            try check(abs(restoredRatio / (Double(w) / Double(h)) - 1) < 0.06, "remove padding without stretching \(w)×\(h)")
        }
        let selected = CGRect(x: 100, y: 50, width: 200, height: 70)
        try check(ImagePipeline.pixelRect(selection: selected, viewSize: CGSize(width: 1440, height: 900), imageSize: CGSize(width: 2880, height: 1800)) == CGRect(x: 200, y: 100, width: 400, height: 140), "Retina point-to-pixel mapping")
        try check(ImagePipeline.screenRect(selection: selected, screenFrame: CGRect(x: -1440, y: 100, width: 1440, height: 900)) == CGRect(x: -1340, y: 880, width: 200, height: 70), "negative-origin secondary screen mapping")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { req in
            guard req.url?.host == "fanyi-api.baidu.com" else { throw TranslatorError.message("unexpected endpoint") }
            return try json(["error_code": 0, "data": ["pasteImg": png.base64EncodedString()]])
        }
        let prepared = try ImagePipeline.prepare(picture)
        let result = try await TranslationClient(session: URLSession(configuration: config)).translate(image: prepared, credentials: credentials, target: "zh")
        try check(result.width == 200 && result.height == 80, "request/response pipeline via isolated URLProtocol (no network)")
        let cancelled = Task { try await Task.sleep(nanoseconds: 1_000_000); try Task.checkCancellation(); _ = try ImagePipeline.prepare(picture) }
        cancelled.cancel()
        do { try await cancelled.value; throw TranslatorError.message("cancellation failed") }
        catch is CancellationError { try check(true, "cancelled operation stops before uploading") }
        print("\(count) checks passed. No real credentials or network calls used.")
    }
}
