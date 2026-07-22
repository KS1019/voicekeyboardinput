#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL VKInstallAudioInputTap(
    AVAudioInputNode *inputNode,
    AVAudioNodeTapBlock tapBlock
);

FOUNDATION_EXPORT BOOL VKRemoveAudioInputTap(AVAudioInputNode *inputNode);

NS_ASSUME_NONNULL_END
