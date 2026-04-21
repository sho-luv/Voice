#import "VoiceExceptionCatcher.h"

@implementation VoiceExceptionCatcher

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"Voice: ObjC exception caught: %@ — %@", exception.name, exception.reason);
        return NO;
    }
}

@end
