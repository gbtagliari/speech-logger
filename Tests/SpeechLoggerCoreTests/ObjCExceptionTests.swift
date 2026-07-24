import Foundation
import Testing

import ObjCExceptionBridge

/// The one guarantee this bridge exists for: an Objective-C exception raised inside the
/// block comes back as a Swift error instead of terminating the process (#55).
///
/// The crash it prevents is invisible to a test suite — an uncaught `NSException` takes
/// the test runner down with it — so what is asserted here is the conversion, and the
/// contention scenario is verified against the real app.
@Suite("Objective-C exception bridge")
struct ObjCExceptionTests {
    @Test("a raised exception comes back as an error")
    func raisedExceptionBecomesAnError() {
        var caught: (any Error)?
        do {
            try ObjCException.catching {
                NSException(
                    name: .invalidArgumentException,
                    reason: "Failed to create tap due to format mismatch", userInfo: nil
                ).raise()
            }
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    /// A log line that says only "something was raised" cannot tell a format mismatch
    /// from a disconnected node, and this error is what reaches `onRecorderStartFailed`.
    @Test("the error names what was raised and why")
    func errorCarriesTheExceptionDetail() {
        var caught: NSError?
        do {
            try ObjCException.catching {
                NSException(
                    name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                    reason: "format mismatch", userInfo: nil
                ).raise()
            }
        } catch {
            caught = error as NSError
        }
        let error = try! #require(caught)
        #expect(error.domain == ObjCExceptionErrorDomain)
        #expect(error.userInfo[ObjCExceptionNameKey] as? String == "com.apple.coreaudio.avfaudio")
        #expect(error.userInfo[ObjCExceptionReasonKey] as? String == "format mismatch")
        #expect(error.localizedDescription.contains("format mismatch"))
        #expect(error.localizedDescription.contains("com.apple.coreaudio.avfaudio"))
    }

    @Test("a block that raises nothing runs and returns")
    func nonRaisingBlockReturns() throws {
        var ran = false
        try ObjCException.catching { ran = true }
        #expect(ran)
    }

    /// An exception with no reason is still an error, not a crash: the bridge must not
    /// depend on the raiser having filled anything in.
    @Test("an exception with no reason still converts")
    func exceptionWithoutReasonConverts() {
        var caught: NSError?
        do {
            try ObjCException.catching {
                NSException(name: NSExceptionName("bare"), reason: nil, userInfo: nil).raise()
            }
        } catch {
            caught = error as NSError
        }
        #expect(caught?.userInfo[ObjCExceptionNameKey] as? String == "bare")
    }
}
