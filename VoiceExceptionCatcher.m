// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

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
