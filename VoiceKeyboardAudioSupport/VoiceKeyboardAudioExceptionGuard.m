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

BOOL VKRemoveAudioInputTap(AVAudioInputNode *inputNode) {
    @try {
        // removeTapOnBus: can raise an Objective-C exception after a media
        // services reset or when the engine has already lost its input node.
        // Keep teardown best-effort and convert that exception to a result
        // instead of allowing it to terminate the process.
        [inputNode removeTapOnBus:0];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

AVAudioFormat * _Nullable VKAudioInputNodeOutputFormat(AVAudioInputNode *inputNode) {
    @try {
        return [inputNode outputFormatForBus:0];
    } @catch (NSException *exception) {
        return nil;
    }
}
