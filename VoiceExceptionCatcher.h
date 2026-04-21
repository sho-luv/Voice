// VoiceExceptionCatcher.h
// Tiny ObjC shim so Swift can catch Obj-C NSExceptions (e.g. from
// AVAudioNode.installTap, CoreAudio device-disconnect races). Swift's
// do/catch does not catch these.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VoiceExceptionCatcher : NSObject
/// Runs `block`. Returns YES if it completed normally, NO if it threw an
/// Obj-C NSException (which is logged to NSLog). Use this to wrap
/// exception-prone APIs like AVAudioNode.installTap.
+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
