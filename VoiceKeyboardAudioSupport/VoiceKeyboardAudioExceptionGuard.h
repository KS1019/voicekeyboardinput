#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL VKInstallAudioInputTap(
    AVAudioInputNode *inputNode,
    AVAudioNodeTapBlock tapBlock
);

FOUNDATION_EXPORT BOOL VKRemoveAudioInputTap(AVAudioInputNode *inputNode);

/// Acquires the input node inside an Objective-C exception boundary.
FOUNDATION_EXPORT AVAudioInputNode * _Nullable VKAudioEngineInputNode(
    AVAudioEngine *engine
);

/// Reads the input format after acquiring the node inside the same boundary.
FOUNDATION_EXPORT AVAudioFormat * _Nullable VKAudioEngineInputFormat(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT BOOL VKInstallAudioEngineInputTap(
    AVAudioEngine *engine,
    AVAudioNodeTapBlock tapBlock
);

FOUNDATION_EXPORT BOOL VKRemoveAudioEngineInputTap(AVAudioEngine *engine);

/// Returns the input node's current format without allowing AVFAudio's
/// Objective-C exception to terminate the containing app or keyboard
/// extension during a route/media-services transition.
FOUNDATION_EXPORT AVAudioFormat * _Nullable VKAudioInputNodeOutputFormat(
    AVAudioInputNode *inputNode
);

/// Prepares and starts an engine inside an Objective-C exception boundary.
FOUNDATION_EXPORT BOOL VKPrepareAndStartAudioEngine(AVAudioEngine *engine);

/// Stops an engine best-effort inside an Objective-C exception boundary.
FOUNDATION_EXPORT BOOL VKStopAudioEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
