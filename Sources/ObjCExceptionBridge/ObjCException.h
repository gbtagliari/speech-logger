#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The domain of every error produced here. One domain, one shape: a raised exception.
extern NSErrorDomain const ObjCExceptionErrorDomain;

/// The raised exception's `name` and `reason`, kept in `userInfo` so a log line can say
/// what was raised and not only that something was.
extern NSErrorUserInfoKey const ObjCExceptionNameKey;
extern NSErrorUserInfoKey const ObjCExceptionReasonKey;

/// The one place in this app allowed to `@try`.
///
/// An `NSException` is **not catchable in Swift**: `do`/`catch` never sees it, no typed
/// error gets a chance, and the process dies. Parts of AVFoundation still signal failure
/// by raising rather than returning an error — `installTapOnBus` rejects a format it
/// disagrees with that way (#55) — so a call like that has to cross Objective-C to be
/// survivable at all.
///
/// Not a general escape hatch. An exception means an API contract was broken and the
/// state afterwards is not guaranteed to be sound, so this is for the narrow case where
/// the alternative is termination and the caller abandons the whole operation on failure.
/// The unwind is not clean either: ARC emits no release for the frames it passes through
/// unless built with `-fobjc-arc-exceptions`, so surviving a raise can leak. Leaking once
/// on the way to a visible failure is the trade — the alternative is a dead process.
@interface ObjCException : NSObject

/// Perform `block`, returning `NO` and setting `error` if it raised an `NSException`.
/// Imported into Swift as `try ObjCException.catching { … }`.
+ (BOOL)catching:(void (NS_NOESCAPE ^)(void))block error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
