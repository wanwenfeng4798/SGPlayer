#import "SGPlaybackController.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SGPlaybackSessionState) {
    SGPlaybackSessionStateIdle,
    SGPlaybackSessionStateLoading,
    SGPlaybackSessionStatePlaying,
    SGPlaybackSessionStatePaused,
    SGPlaybackSessionStateBuffering,
    SGPlaybackSessionStateEnded,
    SGPlaybackSessionStateFailed,
};
typedef NS_ENUM(NSInteger, SGPlaybackLoopMode) {
    SGPlaybackLoopModeNone,
    SGPlaybackLoopModeOne,
    SGPlaybackLoopModeAll,
};
typedef NS_ENUM(NSInteger, SGKernelSelectionPolicy) {
    SGKernelSelectionPolicyManual,
    SGKernelSelectionPolicyPreferNative,
    SGKernelSelectionPolicyPreferFFmpeg,
    SGKernelSelectionPolicyAutomatic, // Inspect actual AVFoundation asset/track support.
};

/// A separately addressable rendition. HLS variants within one playlist remain AVPlayer's responsibility.
@interface SGPlaybackRendition : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title URL:(NSURL *)URL;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSURL *URL;
@end

@interface SGPlaybackItem : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                        renditions:(NSArray<SGPlaybackRendition *> *)renditions;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSArray<SGPlaybackRendition *> *renditions;
@end

/// Main-thread session policy. Owns its controller's source and polls at 10 Hz; call close when finished.
/// Resume positions are scoped to stable item identifiers, never to credential-bearing URLs.
@interface SGPlaybackSession : NSObject
- (instancetype)initWithController:(SGPlaybackController *)controller resumeStore:(nullable NSUserDefaults *)store;
@property(nonatomic, strong, readonly) SGPlaybackController *controller;
@property(nonatomic, copy, readonly) NSArray<SGPlaybackItem *> *items;
@property(nonatomic, readonly) NSInteger selectedIndex; // NSNotFound while empty
@property(nonatomic, readonly) NSInteger selectedRendition;
@property(nonatomic, readonly) SGPlaybackSessionState state;
@property(nonatomic, strong, readonly, nullable) NSError *error;
@property(nonatomic) SGKernelSelectionPolicy kernelPolicy; // automatic by default
/// Keep FFmpeg for features such as VR projection; suppress incompatible native fallback.
@property(nonatomic) BOOL requiresFFmpeg;
@property(nonatomic) SGPlaybackLoopMode loopMode;
@property(nonatomic) BOOL resumeEnabled;              // YES, nil store disables persistence
@property(nonatomic) BOOL automaticAdvance;           // YES
@property(nonatomic) NSTimeInterval loadingTimeout;   // default 20 seconds, clamped to 1...120
@property(nonatomic, readonly) CMTimeRange loopRange; // invalid disables A–B looping
@property(nonatomic, copy, nullable) void (^changed)(SGPlaybackSession *session);
- (BOOL)loadItems:(NSArray<SGPlaybackItem *> *)items
       startIndex:(NSInteger)index
         autoPlay:(BOOL)autoPlay
            error:(NSError **)error;
- (BOOL)selectItemAtIndex:(NSInteger)index;
- (BOOL)next;
- (BOOL)previous;
- (void)selectRenditionAtIndex:(NSInteger)index completion:(void (^)(BOOL success))completion;
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL success))completion;
- (BOOL)setLoopFrom:(CMTime)start to:(CMTime)end; // finite, >=0, B>A, inside known duration
- (void)clearLoop;
- (void)play;
- (void)pause;
- (void)retry;
- (void)saveResumePosition;
/// JSON-safe snapshot: elapsed times are monotonic; URLs and arbitrary error descriptions are excluded.
- (NSDictionary<NSString *, id> *)diagnostics;
- (BOOL)exportDiagnosticsToURL:(NSURL *)URL error:(NSError **)error;
- (void)close;
@end

/// Main-thread exclusive playback group. Explicit activation pauses other registered sessions.
@interface SGPlaybackCoordinator : NSObject
- (void)registerSession:(SGPlaybackSession *)session;
- (void)unregisterSession:(SGPlaybackSession *)session;
- (void)activateSession:(SGPlaybackSession *)session;
- (void)pauseAll;
@end
NS_ASSUME_NONNULL_END
