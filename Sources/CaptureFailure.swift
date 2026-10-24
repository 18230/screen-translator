import Foundation
import ScreenCaptureKit

enum CaptureFailure {
    static func isPermissionDenied(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<4 {
            if current.domain == SCStreamErrorDomain && current.code == SCStreamError.Code.userDeclined.rawValue { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return false
    }

    static func diagnostic(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) / \(error.code)"
    }
}
