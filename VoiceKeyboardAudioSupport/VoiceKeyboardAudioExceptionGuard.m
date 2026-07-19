#import "VoiceKeyboardAudioExceptionGuard.h"

BOOL VKInstallAudioInputTap(
    AVAudioInputNode *inputNode,
    AVAudioNodeTapBlock tapBlock
) {
    @try {
        // AVAudioEngine tap APIs can raise an Objective-C exception for a
        // stale or unavailable input format. Swift cannot catch NSException;
        // convert it to a normal failure so route changes do not terminate
        // the containing app or keyboard extension.
        [inputNode installTapOnBus:0
                         bufferSize:1024
                             format:nil
                              block:tapBlock];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
