#import "ObjCException.h"

NSErrorDomain const ObjCExceptionErrorDomain = @"app.speech-logger.objc-exception";
NSErrorUserInfoKey const ObjCExceptionNameKey = @"ObjCExceptionName";
NSErrorUserInfoKey const ObjCExceptionReasonKey = @"ObjCExceptionReason";

@implementation ObjCException

+ (BOOL)catching:(void (NS_NOESCAPE ^)(void))block error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // No code space: there is one failure here, and the exception's own name is
            // the only discriminator worth carrying.
            NSString *reason = exception.reason ?: @"no reason given";
            *error = [NSError
                errorWithDomain:ObjCExceptionErrorDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               [NSString stringWithFormat:@"%@: %@", exception.name, reason],
                           ObjCExceptionNameKey : exception.name,
                           ObjCExceptionReasonKey : reason,
                       }];
        }
        return NO;
    }
}

@end
