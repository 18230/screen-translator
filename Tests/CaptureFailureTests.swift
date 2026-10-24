import Foundation
import ScreenCaptureKit

@main
struct CaptureFailureTests {
    static func main() {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3801)
        precondition(CaptureFailure.isPermissionDenied(denied))
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        precondition(CaptureFailure.isPermissionDenied(wrapped))
        precondition(!CaptureFailure.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: -3811)))
        precondition(!CaptureFailure.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: -3803)))
        precondition(!CaptureFailure.isPermissionDenied(NSError(domain: NSURLErrorDomain, code: -3801)))
        precondition(CaptureFailure.diagnostic(NSError(domain: "Test", code: 7)) == "Test / 7")
        print("6 capture error checks passed; non-permission failures are not misclassified.")
    }
}
